// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import './UsingStratagemsStore.sol';
import '../interface/StratagemsEvents.sol';

abstract contract UsingStratagemsFunctions is UsingStratagemsStore, StratagemsEvents {
	/// @notice The token used for the game. Each gems on the board contains that token
	IERC20WithIERC2612 internal immutable TOKENS;
	/// @notice the timestamp (in seconds) at which the game start, it start in the commit phase
	uint256 internal immutable START_TIME;
	/// @notice the duration of the commit phase in seconds
	uint256 internal immutable COMMIT_PHASE_DURATION;
	/// @notice the duration of the resolution phase in seconds
	uint256 internal immutable RESOLUTION_PHASE_DURATION;
	/// @notice the max number of level a cell can reach in the game
	uint8 internal immutable MAX_LIFE;
	/// @notice the number of tokens underlying each gems on the board.
	uint256 internal immutable NUM_TOKENS_PER_GEMS;
	/// @notice the address to send the token to when burning
	address payable internal immutable BURN_ADDRESS;

	/// @notice the number of moves a hash represent, after that players make use of furtherMoves
	uint8 internal constant NUM_MOVES_PER_HASH = 32;

	/// @notice Create an instance of a Stratagems game
	/// @param config configuration options for the game
	constructor(Config memory config) {
		TOKENS = config.tokens;
		BURN_ADDRESS = config.burnAddress;
		START_TIME = config.startTime;
		COMMIT_PHASE_DURATION = config.commitPhaseDuration;
		RESOLUTION_PHASE_DURATION = config.resolutionPhaseDuration;
		MAX_LIFE = config.maxLife;
		NUM_TOKENS_PER_GEMS = config.numTokensPerGems;
	}

	function _poke(
		TokenTransfer[] memory transfers,
		uint256 numAddressesToDistributeTo,
		uint64 position
	) internal returns (uint256 newNumAddressesToDistributeTo) {
		(uint32 epoch, ) = _epoch();
		Cell memory cell = _cells[position];
		uint32 lastUpdate = cell.lastEpochUpdate;
		Color color = cell.color;
		uint8 life = cell.life;
		int8 delta = cell.delta;
		if (lastUpdate >= 1 && color != Color.None && life > 0) {
			// the cell is alive here
			(uint8 newLife, uint32 epochUsed) = _computeNewLife(lastUpdate, delta, life, epoch);
			cell.life = newLife;
			cell.lastEpochUpdate = epochUsed;
			if (newLife == 0) {
				// but not anymore here
				cell.delta = 0;
				// we thus distribute the tokens to enemy neighbours
				newNumAddressesToDistributeTo = _distributeDeath(
					transfers,
					numAddressesToDistributeTo,
					position,
					cell.enemymask,
					epochUsed
				);
			}
			_cells[position] = cell;
			// we keep the owner as it is used to compute winnings from this cell
			// alternative would be to always compute the 5 cells distribution
			// but the other 4 cell would have the same problem, they would be half computed anyway
		}
	}

	function _makeCommitment(address player, bytes24 commitmentHash, uint256 inReserve) internal {
		Commitment storage commitment = _commitments[player];

		(uint32 epoch, bool commiting) = _epoch();

		require(commiting, 'IN_RESOLUTION_PHASE');
		require(commitment.epoch == 0 || commitment.epoch == epoch, 'PREVIOUS_COMMITMENT_TO_RESOLVE');

		commitment.hash = commitmentHash;
		commitment.epoch = epoch;

		require(inReserve >= NUM_TOKENS_PER_GEMS, 'NEED_AT_LEAST_ONE_TOKEN_IN_RESERVE');

		emit CommitmentMade(player, epoch, commitmentHash);
	}

	function _resolveMoves(
		address player,
		uint32 epoch,
		Move[] memory moves,
		bool fromReserve
	) internal returns (uint256 newReserveAmount) {
		// max number of transfer is 4 * moves.length (for each move's cell's neighbours potentially being a different account)
		TokenTransfer[] memory transfers = new TokenTransfer[](moves.length * 4);
		uint256 numAddressesToDistributeTo = 0;
		MoveTokens memory tokens;
		for (uint256 i = 0; i < moves.length; i++) {
			(uint256 placed, uint256 burnt, uint256 returned, uint256 newNumAddressesToDistributeTo) = _computeMove(
				transfers,
				numAddressesToDistributeTo,
				player,
				epoch,
				moves[i]
			);
			numAddressesToDistributeTo = newNumAddressesToDistributeTo;
			tokens.tokensPlaced += placed;
			tokens.tokensBurnt += burnt;
			tokens.tokensReturned += returned;
		}

		_multiTransfer(transfers, numAddressesToDistributeTo);

		newReserveAmount = _tokensInReserve[player];

		// Note: even if funds can comes from outside the reserver, we still check it
		// This ensure player have to have a reserve and cannot escape the slash if not
		require(newReserveAmount >= tokens.tokensPlaced + tokens.tokensBurnt);
		if (fromReserve) {
			newReserveAmount -= tokens.tokensPlaced + tokens.tokensBurnt;
			_tokensInReserve[player] = newReserveAmount;
		} else {
			if (tokens.tokensPlaced != 0) {
				TOKENS.transferFrom(player, address(this), tokens.tokensPlaced);
			}
			if (tokens.tokensBurnt != 0) {
				TOKENS.transferFrom(player, BURN_ADDRESS, tokens.tokensBurnt);
			}
		}
		// option to return in reserve ?
		if (tokens.tokensReturned != 0) {
			TOKENS.transfer(player, tokens.tokensReturned);
		}
	}

	function _epoch() internal view virtual returns (uint32 epoch, bool commiting) {
		uint256 epochDuration = COMMIT_PHASE_DURATION + RESOLUTION_PHASE_DURATION;
		require(block.timestamp >= START_TIME, 'GAME_NOT_STARTED');
		uint256 timePassed = block.timestamp - START_TIME;
		epoch = uint32(timePassed / epochDuration + 1); // epoch start at 1
		commiting = timePassed - ((epoch - 1) * epochDuration) < COMMIT_PHASE_DURATION;
	}

	function _getNeihbourEnemiesAliveWithPlayers(
		uint64 position,
		uint8 enemyMask,
		uint32 epoch
	) internal view returns (address[4] memory enemies, uint8 numEnemiesAlive) {
		unchecked {
			int256 x = int256(int32(int256(uint256(position) & 0xFFFFFFFF)));
			int256 y = int256(int32(int256(uint256(position) >> 32)));

			if (enemyMask & 1 == 1) {
				uint256 cellPos = ((uint256(y - 1) << 32) + uint256(x));
				Cell memory cell = _cells[cellPos];
				if (cell.life > 0 || cell.lastEpochUpdate == epoch) {
					enemies[numEnemiesAlive] = _owners[cellPos];
					numEnemiesAlive++;
				}
			}
			if (enemyMask & (1 << 1) == (1 << 1)) {
				uint256 cellPos = ((uint256(y) << 32) + uint256(x - 1));
				Cell memory cell = _cells[cellPos];
				if (cell.life > 0 || cell.lastEpochUpdate == epoch) {
					enemies[numEnemiesAlive] = _owners[cellPos];
					numEnemiesAlive++;
				}
			}
			if (enemyMask & (1 << 2) == (1 << 2)) {
				uint256 cellPos = ((uint256(y + 1) << 32) + uint256(x));
				Cell memory cell = _cells[cellPos];
				if (cell.life > 0 || cell.lastEpochUpdate == epoch) {
					enemies[numEnemiesAlive] = _owners[cellPos];
					numEnemiesAlive++;
				}
			}
			if (enemyMask & (1 << 3) == (1 << 3)) {
				uint256 cellPos = ((uint256(y) << 32) + uint256(x + 1));
				Cell memory cell = _cells[cellPos];
				if (cell.life > 0 || cell.lastEpochUpdate == epoch) {
					enemies[numEnemiesAlive] = _owners[cellPos];
					numEnemiesAlive++;
				}
			}
		}
	}

	function _checkHash(
		bytes24 commitmentHash,
		bytes32 secret,
		Move[] memory moves,
		bytes24 furtherMoves
	) internal pure {
		if (furtherMoves != bytes24(0)) {
			bytes24 computedHash = bytes24(keccak256(abi.encode(secret, moves, furtherMoves)));
			require(commitmentHash == computedHash, 'HASH_NOT_MATCHING');
		} else {
			bytes24 computedHash = bytes24(keccak256(abi.encode(secret, moves)));
			require(commitmentHash == computedHash, 'HASH_NOT_MATCHING');
		}
	}

	function _computeNewLife(
		uint32 lastUpdate,
		int8 delta,
		uint8 life,
		uint32 epoch
	) internal view returns (uint8 newLife, uint32 epochUsed) {
		if (lastUpdate >= 1 && life > 0) {
			uint256 epochDelta = epoch - lastUpdate;
			if (epochDelta > 0) {
				int8 effectiveDelta = delta != 0 ? delta : -1;
				if (effectiveDelta > 0) {
					if (life < MAX_LIFE) {
						uint8 maxEpoch = ((MAX_LIFE - life) + uint8(effectiveDelta) - 1) / uint8(effectiveDelta);
						if (epochDelta > maxEpoch) {
							epochDelta = maxEpoch;
						}

						life += uint8(epochDelta) * uint8(effectiveDelta);
						if (life > MAX_LIFE) {
							life = MAX_LIFE;
						}
						newLife = life;
						epochUsed = lastUpdate + uint32(epochDelta);
					}
				} else if (effectiveDelta < 0) {
					uint8 numEpochBeforeDying = (life + uint8(-effectiveDelta) - 1) / uint8(-effectiveDelta);
					if (epochDelta > numEpochBeforeDying) {
						epochDelta = numEpochBeforeDying;
					}
					uint8 lifeLoss = uint8(epochDelta) * uint8(-effectiveDelta);
					if (lifeLoss > life) {
						newLife = 0;
					} else {
						newLife = life - lifeLoss;
					}
					epochUsed = lastUpdate + uint32(epochDelta);
				}
			}
		}
	}

	function _getUpdatedCell(uint64 position, uint32 epoch) internal view returns (Cell memory updatedCell) {
		// load from state
		updatedCell = _cells[position];
		uint32 lastUpdate = updatedCell.lastEpochUpdate;
		int8 delta = updatedCell.delta;
		uint8 life = updatedCell.life;
		if (lastUpdate >= 1 && life > 0) {
			(uint8 newLife, uint32 epochUsed) = _computeNewLife(lastUpdate, delta, life, epoch);
			if (newLife == 0) {
				updatedCell.delta = 0;
			}
			updatedCell.life = newLife;
			updatedCell.lastEpochUpdate = epochUsed;
		}
	}

	function _updateCellAsDead(uint64 position, Cell memory cell, uint8 newLife, uint32 epochUsed) internal {
		cell.life = newLife;
		cell.lastEpochUpdate = epochUsed;
		cell.delta = 0;
		// max number of transfer is 4 (for each neighbours potentially being a different account)
		TokenTransfer[] memory transfers = new TokenTransfer[](4);
		uint256 numAddressesToTransferTo = _distributeDeath(transfers, 0, position, cell.enemymask, epochUsed);

		_cells[position] = cell;

		_multiTransfer(transfers, numAddressesToTransferTo);
	}

	function _updateCellFromNeighbor(
		uint64 position,
		Cell memory cell,
		uint8 newLife,
		uint32 epoch,
		uint8 neighbourIndex,
		Color oldColor,
		Color newColor
	) internal {
		if (newColor == Color.None) {
			// COLLISION, previous update added a color that should not be there
			if (cell.color == oldColor) {
				cell.delta -= 1;
			} else {
				cell.delta += 1;
				// remove enemy as it was added by COLLISION
				cell.enemymask = cell.enemymask & uint8((1 << neighbourIndex) ^ 0xFF);
			}
		} else if (cell.color == oldColor) {
			// then newColor is different (see assert above)
			cell.enemymask = cell.enemymask | uint8(1 << neighbourIndex);
			cell.delta -= 2;
		} else if (cell.color == newColor) {
			// then old color was different
			cell.delta += (oldColor == Color.None ? int8(1) : int8(2));
			cell.enemymask = cell.enemymask & uint8((1 << neighbourIndex) ^ 0xFF);
		} else if (oldColor == Color.None) {
			// if there were no oldCOlor and the newColor is not your (already checked in previous if clause)
			cell.delta -= 1;
			cell.enemymask = cell.enemymask | uint8(1 << neighbourIndex);
		}
		cell.lastEpochUpdate = epoch;
		cell.life = newLife;
		_cells[position] = cell;
	}

	function _updateCell(
		uint64 position,
		uint32 epoch,
		uint8 neighbourIndex,
		Color oldColor,
		Color newColor
	) internal returns (int8 enemyOrFriend) {
		Cell memory cell = _cells[position];

		// no need to call if oldColor == newColor, so we assume they are different
		assert(oldColor != newColor);
		uint32 lastUpdate = cell.lastEpochUpdate;
		Color color = cell.color;
		enemyOrFriend = color == newColor ? int8(1) : int8(-1);

		if (lastUpdate >= 1 && color != Color.None && cell.life > 0) {
			(uint8 newLife, uint32 epochUsed) = _computeNewLife(lastUpdate, cell.delta, cell.life, epoch);

			if (newLife == 0) {
				_updateCellAsDead(position, cell, newLife, epochUsed);
			} else {
				_updateCellFromNeighbor(position, cell, newLife, epoch, neighbourIndex, oldColor, newColor);
			}
		}
	}

	function _collectTransfer(
		TokenTransfer[] memory collected,
		uint256 numAddressesToDistributeTo,
		TokenTransfer memory newTransfer
	) internal pure returns (uint256) {
		// we look for the newTransfer address in case it is already present
		for (uint256 k = 0; k < numAddressesToDistributeTo; k++) {
			if (collected[k].to == newTransfer.to) {
				// if we found we add the amount
				collected[k].amount += newTransfer.amount;
				// and return
				return numAddressesToDistributeTo;
			}
		}
		// if we did not find that address we add it to the end
		collected[numAddressesToDistributeTo].to = newTransfer.to;
		collected[numAddressesToDistributeTo].amount = newTransfer.amount;
		// and increase the size to lookup
		numAddressesToDistributeTo++;
		return numAddressesToDistributeTo;
	}

	function _multiTransfer(TokenTransfer[] memory transfers, uint256 numAddressesToDistributeTo) internal {
		for (uint256 i = 0; i < numAddressesToDistributeTo; i++) {
			TOKENS.transfer(transfers[i].to, transfers[i].amount);
		}
	}

	function _distributeDeath(
		TokenTransfer[] memory transfers,
		uint256 numAddressesToDistributeTo,
		uint64 position,
		uint8 enemymask,
		uint32 epoch
	) internal view returns (uint256) {
		(address[4] memory enemies, uint8 numEnemiesAlive) = _getNeihbourEnemiesAliveWithPlayers(
			position,
			enemymask,
			epoch
		);
		uint256 total = NUM_TOKENS_PER_GEMS;

		if (numEnemiesAlive == 0) {
			return
				_collectTransfer(
					transfers,
					numAddressesToDistributeTo,
					TokenTransfer({to: payable(_owners[position]), amount: total})
				);
		}

		uint256 amountPerEnenies = total / numEnemiesAlive;
		for (uint8 i = 0; i < numEnemiesAlive; i++) {
			if (i == numEnemiesAlive - 1) {
				amountPerEnenies = total;
			}
			total -= amountPerEnenies;
			numAddressesToDistributeTo = _collectTransfer(
				transfers,
				numAddressesToDistributeTo,
				TokenTransfer({to: payable(enemies[i]), amount: amountPerEnenies})
			);
		}
		return numAddressesToDistributeTo;
	}

	function _updateNeighbours(
		uint64 position,
		uint32 epoch,
		Color oldColor,
		Color newColor
	) internal returns (int8 newDelta) {
		unchecked {
			int256 x = int256(int32(int256(uint256(position) & 0xFFFFFFFF)));
			int256 y = int256(int32(int256(uint256(position) >> 32)));
			uint64 upPosition = uint64((uint256(y - 1) << 32) + uint256(x));
			uint64 leftPosition = uint64((uint256(y) << 32) + uint256(x - 1));
			uint64 downPosition = uint64((uint256(y + 1) << 32) + uint256(x));
			uint64 rightPosition = uint64((uint256(y) << 32) + uint256(x + 1));

			newDelta =
				_updateCell(upPosition, epoch, 0, oldColor, newColor) +
				_updateCell(leftPosition, epoch, 1, oldColor, newColor) +
				_updateCell(downPosition, epoch, 2, oldColor, newColor) +
				_updateCell(rightPosition, epoch, 3, oldColor, newColor);
		}
	}

	// Note on COLLISION
	// we could order color in a certain way so one color takes precedence over another
	// And if the same color was used, we could consider the cell having N owner and N times the number of tokens
	// such cells would be a good target for others
	// On the other end,  on winning agains other cells, owner of such cell would have to divide the winnings
	function _computeMove(
		TokenTransfer[] memory transfers,
		uint256 numAddressesToDistributeTo,
		address player,
		uint32 epoch,
		Move memory move
	)
		internal
		returns (
			uint256 tokensPlaced,
			uint256 tokensBurnt,
			uint256 tokensReturned,
			uint256 newNumAddressesToDistributeTo
		)
	{
		Cell memory currentState = _getUpdatedCell(move.position, epoch);

		if (move.color == Color.None) {
			// this is a leave move
			if (currentState.life == MAX_LIFE && _owners[move.position] == player) {
				// only valid id life == MAX_LIFE and player is owner
				// we reset all, except the lastEpochUpdate
				// this allow us to make sure nobody else can make a move on that cell
				currentState.life = 0;
				currentState.color = Color.None;
				currentState.lastEpochUpdate = epoch;
				currentState.delta = 0;
				currentState.enemymask = 0;
				currentState.epochWhenTokenIsAdded = 0;
				_cells[move.position] = currentState;

				// we can't reset the owner yet as neighbors dieing in epoch should reward the owner

				// we still need to update the neighbors to update their enemymask and delta
				// TODO update neighbors
			}
			// we return
			return (0, 0, NUM_TOKENS_PER_GEMS, numAddressesToDistributeTo);
		}

		if (currentState.life == 0 && currentState.lastEpochUpdate != 0) {
			// we are here because life reach zero (lastEpochUpdate != 0 indicates that the cell was alive and not reset like below)
			// Note: we need to pay attention when we add the leave mechanism
			newNumAddressesToDistributeTo = _distributeDeath(
				transfers,
				numAddressesToDistributeTo,
				move.position,
				currentState.enemymask,
				currentState.lastEpochUpdate
			);
		}

		if (currentState.epochWhenTokenIsAdded == epoch) {
			// COLLISION
			// you get your token back
			// the other player too
			if (currentState.life != 0) {
				_updateNeighbours(move.position, epoch, currentState.color, Color.None);

				// giving back
				_tokensInReserve[_owners[move.position]] += NUM_TOKENS_PER_GEMS;

				currentState.life = 0;
				currentState.color = Color.None;
				currentState.lastEpochUpdate = 0;
				currentState.delta = 0;
				currentState.enemymask = 0;
				_cells[move.position] = currentState;
				_owners[move.position] = address(0);
			} else {
				// we skip
				// tokensPlaced = 0 so this is not counted
				if (currentState.life == 0) {
					_cells[move.position] = currentState;
					_owners[move.position] = address(0);
					// TODO Transfer
				}
			}
		} else if (currentState.life == 0 && (currentState.lastEpochUpdate == 0 || currentState.color != Color.None)) {
			currentState.life = 1;
			currentState.epochWhenTokenIsAdded = epoch;
			currentState.lastEpochUpdate = epoch;

			if (currentState.color != move.color) {
				// only update neighbour if color changed
				_updateNeighbours(move.position, epoch, currentState.color, move.color);
				currentState.color = move.color;
				// TODO fetch neighbours to compute delta
				currentState.delta = 0;
				currentState.enemymask = 0;
			} else {
				// TODO fetch neighbours to compute delta
				currentState.delta = 0;
				currentState.enemymask = 0;
			}

			tokensPlaced = NUM_TOKENS_PER_GEMS;
			_cells[move.position] = currentState;
			_owners[move.position] = player;
			// TODO Transfer
		} else {
			// invalid move
			tokensBurnt = NUM_TOKENS_PER_GEMS;
			if (currentState.life == 0) {
				_cells[move.position] = currentState;
				_owners[move.position] = address(0);
				// TODO Transfer
			}
		}
	}
}
