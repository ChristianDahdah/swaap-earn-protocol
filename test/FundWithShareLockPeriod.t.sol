// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { MockDataFeed } from "src/mocks/MockDataFeed.sol";
import { FundWithShareLockPeriod } from "src/base/permutations/FundWithShareLockPeriod.sol";

// Import Everything from Starter file.
import "test/resources/MainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract FundWithShareLockPeriodTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;

    FundWithShareLockPeriod private fund;

    MockDataFeed private mockUsdcUsd;
    MockDataFeed private mockWethUsd;
    MockDataFeed private mockWbtcUsd;

    uint32 private usdcPosition = 1;
    uint32 private wethPosition = 2;
    uint32 private wbtcPosition = 3;

    uint256 private initialAssets;
    uint256 private initialShares;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 16869780;
        _startFork(rpcKey, blockNumber);

        // Run Starter setUp code.
        _setUp();

        mockUsdcUsd = new MockDataFeed(USDC_USD_FEED);
        mockWethUsd = new MockDataFeed(WETH_USD_FEED);
        mockWbtcUsd = new MockDataFeed(WBTC_USD_FEED);

        // Setup pricing
        PriceRouter.ChainlinkDerivativeStorage memory stor;

        PriceRouter.AssetSettings memory settings;

        uint256 price = uint256(mockUsdcUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockUsdcUsd));
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        price = uint256(mockWethUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockWethUsd));
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        price = uint256(mockWbtcUsd.latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, address(mockWbtcUsd));
        priceRouter.addAsset(WBTC, settings, abi.encode(stor), price);

        // Setup exchange rates:
        // USDC Simulated Price: $1
        // WETH Simulated Price: $2000
        // WBTC Simulated Price: $30,000
        mockUsdcUsd.setMockAnswer(1e8);
        mockWethUsd.setMockAnswer(2_000e8);
        mockWbtcUsd.setMockAnswer(30_000e8);

        // Add adaptors and ERC20 positions to the registry.
        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(USDC));
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(WETH));
        registry.trustPosition(wbtcPosition, address(erc20Adaptor), abi.encode(WBTC));

        // Create Fund.
        string memory fundName = "Share Lock Fund V0.0";
        uint256 initialDeposit = 1e6;

        // Approve new fund to spend assets.
        address fundAddress = deployer.getAddress(fundName);
        deal(address(USDC), address(this), initialDeposit);
        USDC.approve(fundAddress, initialDeposit);

        bytes memory creationCode;
        bytes memory constructorArgs;
        creationCode = type(FundWithShareLockPeriod).creationCode;
        constructorArgs = abi.encode(
            address(this),
            registry,
            USDC,
            fundName,
            fundName,
            usdcPosition,
            abi.encode(true),
            initialDeposit,
            type(uint192).max
        );

        fund = FundWithShareLockPeriod(deployer.deployContract(fundName, creationCode, constructorArgs));

        // Set up remaining fund positions.
        fund.addPositionToCatalogue(wethPosition);
        fund.addPosition(1, wethPosition, abi.encode(true), false);
        fund.addPositionToCatalogue(wbtcPosition);
        fund.addPosition(2, wbtcPosition, abi.encode(true), false);

        // fund.setStrategistPayoutAddress(strategist);

        vm.label(address(fund), "fund");
        vm.label(strategist, "strategist");

        // Approve fund to spend all assets.
        USDC.approve(address(fund), type(uint256).max);

        initialAssets = fund.totalAssets();
        initialShares = fund.totalSupply();
    }

    function testTransfer() external {
        // Change fund share lock period.
        fund.setShareLockPeriod(300);

        // Deposit into fund.
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        uint256 shares = fund.deposit(assets, address(this));

        // Check that withdraw/redeem fails.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.withdraw(assets, address(this), address(this));

        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.redeem(shares, address(this), address(this));

        // Check that transfer and transferFrom fails.
        address me = address(this);
        address friend = vm.addr(55555);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.transfer(friend, shares);

        fund.approve(friend, shares / 2);
        vm.startPrank(friend);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.transferFrom(me, friend, shares);
        vm.stopPrank();

        // Advance time so shares are unlocked.
        vm.warp(block.timestamp + fund.shareLockPeriod());

        // Check that transfer complies with ERC20 standards.
        assertTrue(fund.transfer(friend, shares / 2), "transfer should return true.");
        assertEq(fund.balanceOf(friend), shares / 2, "Friend should have received shares.");
        assertEq(fund.balanceOf(me), shares / 2, "I should have sent shares.");

        // Check that transferFrom complies with ERC20 standards.
        vm.prank(friend);
        assertTrue(fund.transferFrom(me, friend, shares / 2), "transferFrom should return true.");
        assertEq(fund.balanceOf(friend), shares, "Friend should have received shares.");
        assertEq(fund.balanceOf(me), 0, "I should have sent shares.");
        assertEq(fund.allowance(me, friend), 0, "Friend should have used all their allowance.");
    }

    function testChainlinkPriceFeedUpdateSandwichAttack() external {
        // Initialize test Fund.
        string memory fundName = "Share Lock Fund V0.1";
        uint256 initialDeposit = 1e6;

        // Approve new fund to spend assets.
        address fundAddress = deployer.getAddress(fundName);
        deal(address(USDC), address(this), initialDeposit);
        USDC.approve(fundAddress, initialDeposit);

        bytes memory creationCode;
        bytes memory constructorArgs;
        creationCode = type(FundWithShareLockPeriod).creationCode;
        constructorArgs = abi.encode(
            address(this),
            registry,
            USDC,
            fundName,
            fundName,
            usdcPosition,
            abi.encode(true),
            initialDeposit,
            type(uint192).max
        );

        FundWithShareLockPeriod fundA = FundWithShareLockPeriod(
            deployer.deployContract(fundName, creationCode, constructorArgs)
        );

        fundA.addPositionToCatalogue(wethPosition);
        fundA.addPosition(1, wethPosition, abi.encode(true), false);

        // Set up worst case scenario where
        // Fund has all of its funds in mispriced asset(WETH)
        // Chainlink updates price because of max price deviation(1%)

        uint256 assets = 10_000e6;
        deal(address(USDC), address(this), assets);
        USDC.approve(address(fundA), assets);
        fundA.deposit(assets, address(this));
        // Manually rebalance funds from USDC to WETH.
        deal(address(USDC), address(fundA), 0);
        deal(address(WETH), address(fundA), 5e18);

        // Attacker joins fund right before price update.
        address attacker = vm.addr(8349058);
        deal(address(USDC), attacker, assets);
        vm.startPrank(attacker);
        USDC.approve(address(fundA), assets);
        fundA.deposit(assets, attacker);
        vm.stopPrank();

        // Price updates
        mockWethUsd.setMockAnswer(2020e8);

        // Confirm attackers maxWithdraw is zero while shares are locked.
        assertEq(fundA.maxWithdraw(attacker), 0, "Attackers maxWithdraw should be zero while shares are locked.");

        // Confirm attackers maxRedeem is zero while shares are locked.
        assertEq(fundA.maxRedeem(attacker), 0, "Attackers maxRedeem should be zero while shares are locked.");

        vm.startPrank(attacker);
        uint256 shares = fundA.balanceOf(attacker);
        // Attacker tries to redeem their shares.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fundA.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fundA.redeem(shares, attacker, attacker);

        // Attacker tries to transfer shares to another address.
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fundA.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fundA.transfer(address(this), shares);
        vm.stopPrank();

        vm.warp(block.timestamp + fundA.shareLockPeriod());
        mockUsdcUsd.setMockUpdatedAt(block.timestamp);
        mockWethUsd.setMockUpdatedAt(block.timestamp);

        // Confirm attackers shares are worth more once shares are unlocked.
        assertGt(fundA.maxWithdraw(attacker), assets, "Attackers shares should be worth more than deposit.");

        // Note the attacker was able to arbitrage the price feed update, but must wait the share lock period in order to capture profit.
    }

    function testShareLockUpPeriod() external {
        // Try to set lock period to illogical value.
        vm.expectRevert(bytes(abi.encodeWithSelector(FundWithShareLockPeriod.Fund__InvalidShareLockPeriod.selector)));
        fund.setShareLockPeriod(type(uint32).max);

        vm.expectRevert(bytes(abi.encodeWithSelector(FundWithShareLockPeriod.Fund__InvalidShareLockPeriod.selector)));
        fund.setShareLockPeriod(0);

        // Set lock period to reasonable value.
        uint256 newLock = 300;
        fund.setShareLockPeriod(newLock);
        assertEq(fund.shareLockPeriod(), newLock, "Fund share lock should equal newLock.");

        // Make sure user's who join with mint or deposit can not transfer, withdraw, or redeem for the shareLockPeriod.
        uint256 assets = 100e6;
        uint256 shares = 100e18;
        address depositUser = vm.addr(7777);
        address mintUser = vm.addr(77777);
        vm.startPrank(depositUser);
        deal(address(USDC), depositUser, assets);
        USDC.approve(address(fund), assets);
        fund.deposit(assets, depositUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.withdraw(assets, depositUser, depositUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.redeem(shares, depositUser, depositUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.transfer(address(this), shares);
        vm.stopPrank();

        vm.startPrank(mintUser);
        deal(address(USDC), mintUser, assets);
        USDC.approve(address(fund), assets);
        fund.mint(shares, mintUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.withdraw(assets, mintUser, mintUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.redeem(shares, mintUser, mintUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.transfer(address(this), shares);
        vm.stopPrank();

        // Advance block timestamp to end of share lock period.
        vm.warp(block.timestamp + fund.shareLockPeriod());

        // Users can withdraw.
        vm.prank(depositUser);
        fund.withdraw(assets, depositUser, depositUser);

        // Users can transfer.
        vm.prank(mintUser);
        fund.transfer(depositUser, shares);

        // Users can redeem.
        vm.prank(depositUser);
        fund.redeem(shares, depositUser, depositUser);

        // Check that if a user has waited the lock period but then decides to deposit again, they must wait for the new lock period to end.
        vm.startPrank(depositUser);
        deal(address(USDC), depositUser, assets);
        USDC.approve(address(fund), 2 * assets);
        fund.deposit(assets, depositUser);
        // Advance block timestamp to end of share lock period.
        vm.warp(block.timestamp + fund.shareLockPeriod());

        // If user joins again, they must wait the lock period again, even if withdrawing previous amount.
        deal(address(USDC), depositUser, assets);
        fund.deposit(assets, depositUser);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__SharesAreLocked.selector,
                    block.timestamp + fund.shareLockPeriod(),
                    block.timestamp
                )
            )
        );
        fund.withdraw(assets, depositUser, depositUser);
        vm.stopPrank();
    }

    function testDepositOnBehalf() external {
        address user = vm.addr(1111);
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    FundWithShareLockPeriod.Fund__NotApprovedToDepositOnBehalf.selector,
                    address(this)
                )
            )
        );
        fund.deposit(assets, user);

        // Add this address as an approved depositor.
        registry.setApprovedForDepositOnBehalf(address(this), true);
        // Deposits are now allowed.
        fund.deposit(assets, user);
    }
}
