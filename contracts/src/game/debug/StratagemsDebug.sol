// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import 'solidity-kit/solc_0.8/utils/GenericErrors.sol';
import 'solidity-kit/solc_0.8/debug/time/implementations/UsingControlledTime.sol';
import '../internal/UsingStratagemsSetters.sol';
import './IStratagemsWithDebug.sol';

contract StratagemsDebug is UsingStratagemsSetters, UsingControlledTime, IStratagemsDebug {
	constructor(Config memory config) UsingStratagemsSetters(config) {}

	function getRawCell(uint256 id) external view returns (Cell memory) {
		return _cells[id];
	}

	function _getOwner() internal view override returns (address ownerAddress) {
		// solhint-disable-next-line security/no-inline-assembly
		assembly {
			ownerAddress := sload(0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103)
		}
	}

	function forceMoves(address player, Move[] memory moves) external {
		if (msg.sender != _getOwner()) {
			revert NotAuthorized();
		}
		(uint24 epoch, bool commiting) = _epoch();
		if (commiting) {
			epoch--;
		}

		uint256 numTokens = NUM_TOKENS_PER_GEMS * moves.length;
		TOKENS.transferFrom(msg.sender, address(this), numTokens);
		_tokensInReserve[player] += numTokens;
		_resolveMoves(player, epoch, moves, msg.sender);
	}

	function forceCells(DebugCell[] memory cells) external {
		if (msg.sender != _getOwner()) {
			revert NotAuthorized();
		}
		for (uint256 i = 0; i < cells.length; i++) {
			DebugCell memory debugCell = cells[i];
			_cells[debugCell.position] = Cell({
				lastEpochUpdate: debugCell.lastEpochUpdate,
				epochWhenTokenIsAdded: debugCell.epochWhenTokenIsAdded,
				color: debugCell.color,
				life: debugCell.life,
				delta: debugCell.delta,
				enemyMap: debugCell.enemyMap,
				distributionMap: 0 // TODO let debug distributionMap ?
			});
			_owners[debugCell.position] = uint256(uint160(debugCell.owner));
		}
		emit ForceCells(cells);
	}

	function forceSimpleCells(SimpleCell[] memory cells) external {
		if (msg.sender != _getOwner()) {
			revert NotAuthorized();
		}
		(uint24 epoch, ) = _epoch();

		for (uint256 i = 0; i < cells.length; i++) {
			SimpleCell memory simpleCell = cells[i];
			if (_cells[simpleCell.position].lastEpochUpdate != 0) {
				revert InvalidCellOverwrite();
			}
			TOKENS.transferFrom(msg.sender, address(this), NUM_TOKENS_PER_GEMS);

			(int8 delta, uint8 enemyMap) = _updateNeighbosrDelta(simpleCell.position, simpleCell.color, epoch);

			_cells[simpleCell.position] = Cell({
				lastEpochUpdate: epoch,
				epochWhenTokenIsAdded: epoch,
				color: simpleCell.color,
				life: simpleCell.life,
				delta: delta,
				enemyMap: enemyMap,
				distributionMap: 0 // TODO let debug distributionMap ?
			});
			_owners[simpleCell.position] = uint256(uint160(simpleCell.owner));
		}

		for (uint256 i = 0; i < cells.length; i++) {
			uint256 position = cells[i].position;
			Cell memory cell = _cells[position];

			// we act as if the token were added in previous epochs
			// this is so it does not affect the resolution phase
			int256 potentialLife = int256(uint256(cell.life)) - cell.delta;
			if (potentialLife < 0) {
				potentialLife = 0;
			}
			if (uint256(potentialLife) > MAX_LIFE) {
				unchecked {
					int32 x = int32(int256(uint256(position) & 0xFFFFFFFF));
					int32 y = int32(int256(uint256(position) >> 32));
					revert InvalidLifeConfiguration(uint256(potentialLife), x, y);
				}
			}
			cell.life = uint8(uint256(potentialLife));

			_cells[position] = Cell({
				lastEpochUpdate: epoch - 1,
				epochWhenTokenIsAdded: epoch - 1,
				color: cell.color,
				life: cell.life,
				delta: cell.delta,
				enemyMap: cell.enemyMap,
				distributionMap: 0 // TODO let debug distributionMap ?
			});
		}

		emit ForceSimpleCells(epoch, cells);
	}

	function isEnemyOrFriend(Color a, Color b) internal pure returns (int8) {
		if (a != Color.None && b != Color.None) {
			return a == b ? int8(1) : int8(-1);
		}
		return 0;
	}

	function _computeDelta(uint64 position, Color color) internal view returns (int8 delta, uint8 enemyMap) {
		unchecked {
			int256 x = int256(int32(int256(uint256(position) & 0xFFFFFFFF)));
			int256 y = int256(int32(int256(uint256(position) >> 32)));
			{
				uint64 upPosition = uint64((uint256(y - 1) << 32) + uint256(x));
				int8 enemyOrFriend = isEnemyOrFriend(color, _cells[upPosition].color);
				if (enemyOrFriend < 0) {
					enemyMap = enemyMap | 1;
				}
				delta += enemyOrFriend;
			}
			{
				uint64 leftPosition = uint64((uint256(y) << 32) + uint256(x - 1));
				int8 enemyOrFriend = isEnemyOrFriend(color, _cells[leftPosition].color);
				if (enemyOrFriend < 0) {
					enemyMap = enemyMap | 1;
				}
				delta += enemyOrFriend;
			}

			{
				uint64 downPosition = uint64((uint256(y + 1) << 32) + uint256(x));
				int8 enemyOrFriend = isEnemyOrFriend(color, _cells[downPosition].color);
				if (enemyOrFriend < 0) {
					enemyMap = enemyMap | 1;
				}
				delta += enemyOrFriend;
			}
			{
				uint64 rightPosition = uint64((uint256(y) << 32) + uint256(x + 1));
				int8 enemyOrFriend = isEnemyOrFriend(color, _cells[rightPosition].color);
				if (enemyOrFriend < 0) {
					enemyMap = enemyMap | 1;
				}
				delta += enemyOrFriend;
			}
		}
	}

	function _updateNeighbosrDelta(
		uint64 center,
		Color color,
		uint24 epoch
	) internal returns (int8 delta, uint8 enemyMap) {
		unchecked {
			int256 x = int256(int32(int256(uint256(center) & 0xFFFFFFFF)));
			int256 y = int256(int32(int256(uint256(center) >> 32)));
			{
				uint64 upPosition = uint64((uint256(y - 1) << 32) + uint256(x));
				Cell memory cell = _cells[upPosition];
				if (cell.color != Color.None) {
					int8 enemyOrFriend = isEnemyOrFriend(color, cell.color);
					if (enemyOrFriend < 0) {
						enemyMap = enemyMap | 1;
					}
					delta += enemyOrFriend;
					_updateCellFromNeighbor(upPosition, cell, cell.life, epoch, 2, Color.None, color);
				}
			}
			{
				uint64 leftPosition = uint64((uint256(y) << 32) + uint256(x - 1));
				Cell memory cell = _cells[leftPosition];
				if (cell.color != Color.None) {
					int8 enemyOrFriend = isEnemyOrFriend(color, cell.color);
					if (enemyOrFriend < 0) {
						enemyMap = enemyMap | 2;
					}
					delta += enemyOrFriend;
					_updateCellFromNeighbor(leftPosition, cell, cell.life, epoch, 3, Color.None, color);
				}
			}

			{
				uint64 downPosition = uint64((uint256(y + 1) << 32) + uint256(x));
				Cell memory cell = _cells[downPosition];
				if (cell.color != Color.None) {
					int8 enemyOrFriend = isEnemyOrFriend(color, cell.color);
					if (enemyOrFriend < 0) {
						enemyMap = enemyMap | 4;
					}
					delta += enemyOrFriend;
					_updateCellFromNeighbor(downPosition, cell, cell.life, epoch, 0, Color.None, color);
				}
			}
			{
				uint64 rightPosition = uint64((uint256(y) << 32) + uint256(x + 1));
				Cell memory cell = _cells[rightPosition];
				if (cell.color != Color.None) {
					int8 enemyOrFriend = isEnemyOrFriend(color, cell.color);
					if (enemyOrFriend < 0) {
						enemyMap = enemyMap | 8;
					}
					delta += enemyOrFriend;
					_updateCellFromNeighbor(rightPosition, cell, cell.life, epoch, 1, Color.None, color);
				}
			}
		}
	}
}
