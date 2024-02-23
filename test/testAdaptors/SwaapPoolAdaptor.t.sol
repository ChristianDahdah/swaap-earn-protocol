// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.21;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { SwaapPoolAdaptor } from "src/modules/adaptors/Swaap/SwaapPoolAdaptor.sol";
import { ILiquidityGaugev3Custom } from "src/interfaces/external/Balancer/ILiquidityGaugev3Custom.sol";
import { IBasePool } from "src/interfaces/external/Balancer/typically-npm/IBasePool.sol";
import { IVault, IAsset, IERC20, IFlashLoanRecipient } from "@balancer/interfaces/contracts/vault/IVault.sol";
import { IBalancerRelayer } from "src/interfaces/external/Balancer/IBalancerRelayer.sol";
import { MockBalancerPoolAdaptor } from "src/mocks/adaptors/MockBalancerPoolAdaptor.sol";
import { SwaapSafeguardPoolExtension } from "src/modules/price-router/Extensions/Swaap/SwaapSafeguardPoolExtension.sol";
import { WstEthExtension } from "src/modules/price-router/Extensions/Lido/WstEthExtension.sol";
import { CellarWithShareLockFlashLoansWhitelisting } from "src/base/permutations/CellarWithShareLockFlashLoansWhitelisting.sol";
import { IUniswapV3Pool } from "@uniswapV3C/interfaces/IUniswapV3Pool.sol";
import { Cellar } from "src/base/Cellar.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// Import Everything from Starter file.
import "test/resources/SwaapMainnetStarter.t.sol";

import { AdaptorHelperFunctions } from "test/resources/AdaptorHelperFunctions.sol";

contract SwaapPoolAdaptorTest is MainnetStarterTest, AdaptorHelperFunctions {
    using SafeTransferLib for ERC20;
    using Math for uint256;
    using stdStorage for StdStorage;
    using Address for address;
    using SafeTransferLib for address;

    SwaapPoolAdaptor private swaapPoolAdaptor;
    SwaapSafeguardPoolExtension private swaapSafeguardPoolExtension;

    CellarWithShareLockFlashLoansWhitelisting private cellar;

    uint32 private usdcPosition = 1;
    uint32 private wethPosition = 2;
    uint32 private safeguardUsdcWethPosition = 3;

    uint256 public initialAssets;
    uint256 public expectedUSDC_WETH_SPTPrice;

    function setUp() external {
        // Setup forked environment.
        string memory rpcKey = "MAINNET_RPC_URL";
        uint256 blockNumber = 19035690;
        _startFork(rpcKey, blockNumber);
        // expected price of WETH_USDC_SPT @ forked block
        expectedUSDC_WETH_SPTPrice = 0.2328e8;

        // Run Starter setUp code.
        _setUp();

        swaapPoolAdaptor = new SwaapPoolAdaptor(swaapVault, address(erc20Adaptor));
        swaapSafeguardPoolExtension = new SwaapSafeguardPoolExtension(priceRouter, IVault(swaapVault));

        PriceRouter.ChainlinkDerivativeStorage memory stor;
        PriceRouter.AssetSettings memory settings;

        // Add WETH pricing.
        uint256 price = uint256(IChainlinkAggregator(WETH_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, WETH_USD_FEED);
        priceRouter.addAsset(WETH, settings, abi.encode(stor), price);

        // Add USDC pricing.
        price = uint256(IChainlinkAggregator(USDC_USD_FEED).latestAnswer());
        settings = PriceRouter.AssetSettings(CHAINLINK_DERIVATIVE, USDC_USD_FEED);
        priceRouter.addAsset(USDC, settings, abi.encode(stor), price);

        // Add pricing.
        settings = PriceRouter.AssetSettings(EXTENSION_DERIVATIVE, address(swaapSafeguardPoolExtension));
        priceRouter.addAsset(USDC_WETH_SPT, settings, abi.encode(), expectedUSDC_WETH_SPTPrice);

        // Setup Cellar:
        registry.trustAdaptor(address(swaapPoolAdaptor));

        registry.trustPosition(usdcPosition, address(erc20Adaptor), abi.encode(address(USDC))); // holdingPosition for tests
        registry.trustPosition(wethPosition, address(erc20Adaptor), abi.encode(address(WETH))); // holdingPosition for tests
        registry.trustPosition(safeguardUsdcWethPosition, address(erc20Adaptor), abi.encode(address(USDC_WETH_SPT)));

        string memory cellarName = "Swaap Cellar V0.0";
        uint256 initialDeposit = 1e6;

        cellar = _createCellarWithShareLockFlashLoansWhitelisting(
            cellarName,
            USDC, // holdingAsset,
            usdcPosition, // holdingPosition,
            abi.encode(0), // holdingPositionConfig,
            initialDeposit,
            swaapVault
        );

        cellar.addAdaptorToCatalogue(address(swaapPoolAdaptor));
        cellar.addAdaptorToCatalogue(address(erc20Adaptor));
        cellar.addAdaptorToCatalogue(address(swapWithUniswapAdaptor));

        USDC.approve(address(cellar), type(uint256).max);

        cellar.setRebalanceDeviation(0.005e18);
        cellar.addPositionToCatalogue(wethPosition);
        cellar.addPositionToCatalogue(safeguardUsdcWethPosition);

        cellar.addPosition(0, wethPosition, abi.encode(0), false);
        cellar.addPosition(0, safeguardUsdcWethPosition, abi.encode(USDC_WETH_SPT), false);

        initialAssets = cellar.totalAssets();
    }

    // ========================================= HAPPY PATH TESTS =========================================

    function testSwaapFlashLoans() external {
        uint256 assets = 100e6;
        deal(address(USDC), address(this), assets);
        USDC.approve(address(cellar), assets);

        cellar.deposit(assets, address(this));

        address[] memory tokens = new address[](1);
        tokens[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10_000e6;
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCallsInFlashLoan = new bytes[](2);
        adaptorCallsInFlashLoan[0] = _createBytesDataForSwapWithUniv3(USDC, WETH, 500, 5_00e6);
        adaptorCallsInFlashLoan[1] = _createBytesDataForSwapWithUniv3(WETH, USDC, 500, type(uint256).max);
        data[0] = Cellar.AdaptorCall({ adaptor: address(swapWithUniswapAdaptor), callData: adaptorCallsInFlashLoan });
        bytes memory flashLoanData = abi.encode(data);

        data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _createBytesDataToMakeFlashLoanFromBalancer(tokens, amounts, flashLoanData);

        data[0] = Cellar.AdaptorCall({ adaptor: address(swaapPoolAdaptor), callData: adaptorCalls });
        cellar.callOnAdaptor(data);

        assertApproxEqRel(
            cellar.totalAssets(),
            initialAssets + assets,
            0.005e18,
            "Cellar totalAssets should be relatively unchanged."
        );
    }

    function testBalancerFlashLoanChecks() external {
        // Try calling `receiveFlashLoan` directly on the Cellar.
        IERC20[] memory tokens;
        uint256[] memory amounts;
        uint256[] memory feeAmounts;
        bytes memory userData;

        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    CellarWithShareLockFlashLoansWhitelisting.Cellar__CallerNotBalancerVault.selector
                )
            )
        );
        cellar.receiveFlashLoan(tokens, amounts, feeAmounts, userData);

        // Attacker tries to initiate a flashloan to control the Cellar.
        vm.expectRevert(
            bytes(abi.encodeWithSelector(CellarWithShareLockFlashLoansWhitelisting.Cellar__ExternalInitiator.selector))
        );
        IVault(swaapVault).flashLoan(IFlashLoanRecipient(address(cellar)), tokens, amounts, userData);
    }

    /**
     * @notice check that assetsUsed() works which also checks assetOf() works
     */
    function testAssetsUsed() external {
        bytes memory adaptorData = abi.encode(address(USDC_WETH_SPT));
        ERC20[] memory actualAsset = erc20Adaptor.assetsUsed(adaptorData);
        address actualAssetAddress = address(actualAsset[0]);
        assertEq(actualAssetAddress, address(USDC_WETH_SPT));
    }

    function testIsDebt() external {
        bool result = swaapPoolAdaptor.isDebt();
        assertEq(result, false);
    }

    function testDepositToHoldingPosition() external {
        string memory cellarName = "Swaap LP Cellar V0.0";
        uint256 initialDeposit = 1e12;

        Cellar swaapCellar = _createCellarWithShareLockFlashLoansWhitelisting(
            cellarName,
            USDC_WETH_SPT,
            safeguardUsdcWethPosition,
            abi.encode(0),
            initialDeposit,
            swaapVault
        );

        uint256 totalAssetsBefore = swaapCellar.totalAssets();

        uint256 assetsToDeposit = 100e18;
        deal(address(USDC_WETH_SPT), address(this), assetsToDeposit);
        USDC_WETH_SPT.approve(address(swaapCellar), assetsToDeposit);
        swaapCellar.deposit(assetsToDeposit, address(this));

        uint256 totalAssetsAfter = swaapCellar.totalAssets();

        assertEq(
            totalAssetsAfter,
            totalAssetsBefore + assetsToDeposit,
            "TotalAssets should have increased by assetsToDeposit"
        );
    }

    // ========================================= Join Happy Paths =========================================

    function testTotalAssetsAfterJoin(uint256 assets) external {
        // User Joins Cellar.
        assets = bound(assets, 0.1e6, 1_000_000e6);

        // make sure that the minted spt value corresponds to the expected value
        uint256 eqSPT = priceRouter.getValue(USDC, assets, USDC_WETH_SPT);

        assertGt(eqSPT, 0, "Wrong configuration of the test, eqSPT should be greater than 0");

        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _dealAndGetJoinPoolAdaptorData(USDC_WETH_SPT, eqSPT);

        uint256 totalAssetsBefore = cellar.totalAssets();

        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);

        data[0] = Cellar.AdaptorCall({ adaptor: address(swaapPoolAdaptor), callData: adaptorCalls });
        cellar.callOnAdaptor(data);

        uint256 totalAssetsAfter = cellar.totalAssets();

        assertApproxEqRel(
            totalAssetsAfter,
            totalAssetsBefore,
            0.0001e18, // 0.01%
            "Cellar totalAssets should be relatively unchanged in a swaap pool join with no trades."
        );

        assertApproxEqRel(
            cellar.totalAssets(),
            assets + initialAssets,
            0.0001e18, // 0.01%
            "Cellar totalAssets should be correct after joining a swaap pool."
        );

        assertEq(
            USDC_WETH_SPT.balanceOf(address(cellar)),
            eqSPT,
            "Cellar should have received the exact number of SPT."
        );
    }

    function testAllowlistJoin(uint256 assets) external {
        assets = bound(assets, 0.1e6, 1_000_000e6);

        // make sure that the minted spt value corresponds to the expected value
        uint256 eqSPT = priceRouter.getValue(USDC, assets, USDC_WETH_SPT);

        uint256 signerKey = 0xA11CE;

        address aliceAddress = vm.addr(signerKey);

        bytes memory signature = _swaapSafeguardAllowlistSignature(
            address(cellar),
            block.timestamp + 10,
            signerKey,
            bytes32(0xc52c5924ef6f12369246860438537534d07daf9e4ceb0b897a712b50f74b1ad0) // domain separator of USDC_WETH_SPT
        );

        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _dealAndGetJoinAllowlistPoolAdaptorData(
            USDC_WETH_SPT,
            eqSPT,
            block.timestamp + 10,
            signature
        );

        // USDC_WETH_SPT owner
        vm.prank(0xD6Ff6aBb93EF058A474769f0d05C7fEF440920F8);
        (bool success, ) = address(USDC_WETH_SPT).call(abi.encodeWithSelector(0x6c19e783, aliceAddress)); // set signer to alice
        require(success, "failed to set signer to alice");

        // USDC_WETH_SPT setAllowlist setter
        vm.prank(0xf360beb38Edd85637eB6D893667AA12fb2d7CE2c);
        (success, ) = address(USDC_WETH_SPT).call(abi.encodeWithSelector(0x7b749c45, true)); // set signer to alice
        require(success, "failed to set allowlist to true");

        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        data[0] = Cellar.AdaptorCall({ adaptor: address(swaapPoolAdaptor), callData: adaptorCalls });

        cellar.callOnAdaptor(data);

        assertApproxEqRel(
            cellar.totalAssets(),
            initialAssets + assets,
            0.0001e18, // 0.01%
            "Cellar totalAssets should be correct after joining a swaap pool with allowlist."
        );

        assertEq(
            USDC_WETH_SPT.balanceOf(address(cellar)),
            eqSPT,
            "Cellar should have received the exact number of SPT when allowlist is on."
        );
    }

    // ========================================= Exit Happy Paths =========================================

    function testTotalAssetsAfterExit(uint256 assets) external {
        // User Joins Cellar.
        assets = bound(assets, 0.1e6, 500_000e6); // make sure that the max exit amount is less than the swaap pool tvl

        // make sure that the minted spt value corresponds to the expected value
        uint256 eqSPT = priceRouter.getValue(USDC, assets, USDC_WETH_SPT);

        assertGt(eqSPT, 0, "Wrong configuration of the test, eqSPT should be greater than 0");

        // get exit pool data.
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _dealAndGetExitPoolAdaptorData(USDC_WETH_SPT, eqSPT);

        uint256 totalAssetsBefore = cellar.totalAssets();

        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);

        data[0] = Cellar.AdaptorCall({ adaptor: address(swaapPoolAdaptor), callData: adaptorCalls });
        cellar.callOnAdaptor(data);

        uint256 totalAssetsAfter = cellar.totalAssets();

        assertApproxEqRel(
            totalAssetsAfter,
            totalAssetsBefore,
            0.0001e18, // 0.01%
            "Cellar totalAssets should be relatively unchanged in a swaap pool exit with no trades."
        );

        assertApproxEqRel(
            totalAssetsAfter,
            assets + initialAssets,
            0.0001e18, // 0.01%
            "Cellar totalAssets should be correct after exiting swaap pool."
        );

        assertEq(USDC_WETH_SPT.balanceOf(address(cellar)), 0, "Cellar should have no USDC_WETH_SPT left.");
    }

    function testSwaapProportionalExitPool(uint256 assets) external {
        assets = bound(assets, 0.1e6, 500_000e6);

        // Simulate a pool deposit by minting to the cellar spts.
        uint256 sptAmount = priceRouter.getValue(USDC, assets, USDC_WETH_SPT);
        deal(address(USDC), address(cellar), 0); // set cellar USDC balance to 0 for this test
        deal(address(USDC_WETH_SPT), address(cellar), sptAmount); // simulate deposit of spt into cellar

        assertApproxEqRel(
            cellar.totalAssets(),
            assets,
            0.0001e18, // 0.01%
            "Cellar should have received expected value of spt."
        );

        // Have strategist exit pool in underlying tokens.
        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);
        bytes[] memory adaptorCalls = new bytes[](1);

        ERC20[] memory poolAssets = new ERC20[](2);

        poolAssets[0] = USDC;
        poolAssets[1] = WETH;

        uint256[] memory minAmountsOut = new uint256[](2);

        adaptorCalls[0] = _createBytesDataToExitSwaapPool(USDC_WETH_SPT, poolAssets, minAmountsOut, sptAmount);
        data[0] = Cellar.AdaptorCall({ adaptor: address(swaapPoolAdaptor), callData: adaptorCalls });

        cellar.callOnAdaptor(data);

        uint256[] memory baseAmounts = new uint256[](2);
        baseAmounts[0] = USDC.balanceOf(address(cellar));
        baseAmounts[1] = WETH.balanceOf(address(cellar));

        uint256 expectedValueOut = priceRouter.getValues(poolAssets, baseAmounts, USDC);

        assertGe(expectedValueOut, 0, "Price router might be misconfigured.");

        assertApproxEqRel(
            cellar.totalAssets(),
            expectedValueOut,
            0.0001e18, // 0.01%
            "Cellar should have received expected value out."
        );

        assertGt(baseAmounts[0], 0, "Cellar should have got USDC.");
        assertGt(baseAmounts[1], 0, "Cellar should have got WETH.");

        assertEq(ERC20(USDC_WETH_SPT).balanceOf(address(cellar)), 0, "Cellar should have redeemed all SPTs.");
    }

    // ========================================= Reverts =========================================

    function testJoinPoolReverts() external {
        // Have strategist exit pool but tokens out are not supported by the cellar.
        uint256 sptUsdcUsdtAmount = 100e18;

        // revert on unsupported spt token (usdc-usdt pool)
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _dealAndGetJoinPoolAdaptorData(USDC_USDT_SPT, sptUsdcUsdtAmount);

        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);

        data[0] = Cellar.AdaptorCall({ adaptor: address(swaapPoolAdaptor), callData: adaptorCalls });
        vm.expectRevert(
            bytes(
                abi.encodeWithSelector(
                    BaseAdaptor.BaseAdaptor__PositionNotUsed.selector,
                    abi.encode(address(USDC_USDT_SPT))
                )
            )
        );

        cellar.callOnAdaptor(data);

        // revert on tokensIn and poolTokens length mismatch
        adaptorCalls[0] = _createBytesDataToJoinSwaapPool(
            USDC_WETH_SPT,
            new ERC20[](0),
            new uint256[](0),
            sptUsdcUsdtAmount
        );

        vm.expectRevert(abi.encodeWithSelector(SwaapPoolAdaptor.SwaapPoolAdaptor___LengthMismatch.selector));

        cellar.callOnAdaptor(data);

        // revert on tokensIn and amountsIn length mismatch
        adaptorCalls[0] = _createBytesDataToJoinSwaapPool(
            USDC_WETH_SPT,
            new ERC20[](2),
            new uint256[](0),
            sptUsdcUsdtAmount
        );

        vm.expectRevert(abi.encodeWithSelector(SwaapPoolAdaptor.SwaapPoolAdaptor___LengthMismatch.selector));
        cellar.callOnAdaptor(data);

        // revert on poolTokens and tokensOut mismatch
        adaptorCalls[0] = _createBytesDataToJoinSwaapPool(
            USDC_WETH_SPT,
            new ERC20[](2),
            new uint256[](2),
            sptUsdcUsdtAmount
        );

        vm.expectRevert(
            abi.encodeWithSelector(SwaapPoolAdaptor.SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch.selector)
        );
        cellar.callOnAdaptor(data);
    }

    function testExitPoolReverts() external {
        // Have strategist exit pool but tokens out are not supported by the cellar.
        uint256 sptUsdcUsdtAmount = 100e18;

        // revert on unsupported token out (usdt)
        bytes[] memory adaptorCalls = new bytes[](1);
        adaptorCalls[0] = _dealAndGetExitPoolAdaptorData(USDC_USDT_SPT, sptUsdcUsdtAmount);

        Cellar.AdaptorCall[] memory data = new Cellar.AdaptorCall[](1);

        data[0] = Cellar.AdaptorCall({ adaptor: address(swaapPoolAdaptor), callData: adaptorCalls });
        vm.expectRevert(
            bytes(abi.encodeWithSelector(BaseAdaptor.BaseAdaptor__PositionNotUsed.selector, abi.encode(address(USDT))))
        );

        cellar.callOnAdaptor(data);

        // revert on tokensOut and poolTokens length mismatch
        adaptorCalls[0] = _createBytesDataToExitSwaapPool(
            USDC_WETH_SPT,
            new ERC20[](0),
            new uint256[](0),
            sptUsdcUsdtAmount
        );

        vm.expectRevert(abi.encodeWithSelector(SwaapPoolAdaptor.SwaapPoolAdaptor___LengthMismatch.selector));

        cellar.callOnAdaptor(data);

        // revert on tokensOut and amountsOut length mismatch
        adaptorCalls[0] = _createBytesDataToExitSwaapPool(
            USDC_WETH_SPT,
            new ERC20[](2),
            new uint256[](0),
            sptUsdcUsdtAmount
        );

        vm.expectRevert(abi.encodeWithSelector(SwaapPoolAdaptor.SwaapPoolAdaptor___LengthMismatch.selector));
        cellar.callOnAdaptor(data);

        // revert on poolTokens and tokensOut mismatch
        adaptorCalls[0] = _createBytesDataToExitSwaapPool(
            USDC_WETH_SPT,
            new ERC20[](2),
            new uint256[](2),
            sptUsdcUsdtAmount
        );

        vm.expectRevert(
            abi.encodeWithSelector(SwaapPoolAdaptor.SwaapPoolAdaptor___PoolTokenAndExpectedTokenMismatch.selector)
        );
        cellar.callOnAdaptor(data);
    }

    function testFailTransferEthToCellar() external {
        // This test verifies that native eth transfers to the cellar will revert.
        // So even if the strategist somehow manages to make a swap send native eth
        // to the cellar it will revert.

        deal(address(this), 1 ether);
        address(cellar).safeTransferETH(1 ether);
    }

    // ========================================= HELPERS =========================================

    // function getPoolTokens(
    //     bytes32 poolId
    // ) external view returns (IERC20[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock) {
    //     return IVault(vault).getPoolTokens(poolId);
    // }

    function _simulatePoolJoin(address target, ERC20 tokenIn, uint256 amountIn, ERC20 bpt) internal {
        // Convert Value in to terms of bpt.
        uint256 valueInBpt = priceRouter.getValue(tokenIn, amountIn, bpt);

        // Use deal to mutate targets balances.
        uint256 tokenInBalance = tokenIn.balanceOf(target);
        deal(address(tokenIn), target, tokenInBalance - amountIn);
        uint256 bptBalance = bpt.balanceOf(target);
        deal(address(bpt), target, bptBalance + valueInBpt);
    }

    function _simulatePoolExit(address target, ERC20 bptIn, uint256 amountIn, ERC20 tokenOut) internal {
        // Convert Value in to terms of bpt.
        uint256 valueInTokenOut = priceRouter.getValue(bptIn, amountIn, tokenOut);

        // Use deal to mutate targets balances.
        uint256 bptBalance = bptIn.balanceOf(target);
        deal(address(bptIn), target, bptBalance - amountIn);
        uint256 tokenOutBalance = tokenOut.balanceOf(target);
        deal(address(tokenOut), target, tokenOutBalance + valueInTokenOut);
    }

    function _getUnderlyingBalancesGivenShares(
        ERC20 pool,
        uint256 sptShares
    ) internal returns (ERC20[] memory, uint256[] memory) {
        bytes32 poolId = IBasePool(address(pool)).getPoolId();
        (IERC20[] memory poolTokens, uint256[] memory balances, ) = IVault(swaapVault).getPoolTokens(poolId);

        (, uint256[] memory amountsIn) = IBasePool(address(pool)).queryJoin(
            poolId,
            address(0), // sender (irrelevant)
            address(0), // recipient (irrelevant)
            balances, // pool balance
            0, // last change block (irrelevant)
            0, // swap fee percentage (irrelevant)
            abi.encode(SwaapPoolAdaptor.JoinKind.ALL_TOKENS_IN_FOR_EXACT_SPT_OUT, sptShares) // userData to join
        );

        ERC20[] memory convertedPoolTokens = new ERC20[](poolTokens.length);

        for (uint256 i; i < poolTokens.length; i++) {
            convertedPoolTokens[i] = ERC20(address(poolTokens[i])); // convert IERC20 to ERC20
        }

        return (convertedPoolTokens, amountsIn);
    }

    // adds necessary tokens to join a pool to the cellar
    function _dealAndGetJoinAllowlistPoolAdaptorData(
        ERC20 pool,
        uint256 sptShares,
        uint256 deadline,
        bytes memory signature
    ) internal returns (bytes memory) {
        (ERC20[] memory underlyingTokens, uint256[] memory underlyingBalances) = _getUnderlyingBalancesGivenShares(
            pool,
            sptShares
        );

        // give the cellar the necessary tokens to join the pool (+ keep old balance)
        for (uint256 i; i < underlyingBalances.length; i++) {
            deal(
                address(underlyingTokens[i]),
                address(cellar),
                underlyingTokens[i].balanceOf(address(cellar)) + underlyingBalances[i]
            );
        }

        return
            _createBytesDataToJoinAllowlistSwaapPool(
                pool,
                underlyingTokens,
                underlyingBalances,
                sptShares,
                deadline,
                signature
            );
    }

    // adds necessary tokens to join a pool to the cellar
    function _dealAndGetJoinPoolAdaptorData(ERC20 pool, uint256 sptShares) internal returns (bytes memory) {
        (ERC20[] memory underlyingTokens, uint256[] memory underlyingBalances) = _getUnderlyingBalancesGivenShares(
            pool,
            sptShares
        );

        // give the cellar the necessary tokens to join the pool (+ keep old balance)
        for (uint256 i; i < underlyingBalances.length; i++) {
            deal(
                address(underlyingTokens[i]),
                address(cellar),
                underlyingTokens[i].balanceOf(address(cellar)) + underlyingBalances[i]
            );
        }

        return _createBytesDataToJoinSwaapPool(pool, underlyingTokens, underlyingBalances, sptShares);
    }

    // adds necessary tokens to exit a pool to the cellar
    function _dealAndGetExitPoolAdaptorData(ERC20 pool, uint256 sptShares) internal returns (bytes memory) {
        bytes32 poolId = IBasePool(address(pool)).getPoolId();
        (IERC20[] memory poolTokens, , ) = IVault(swaapVault).getPoolTokens(poolId);

        ERC20[] memory underlyingTokens = new ERC20[](poolTokens.length);

        // convert IERC20 to ERC20
        for (uint256 i; i < poolTokens.length; i++) {
            underlyingTokens[i] = ERC20(address(poolTokens[i])); // convert IERC20 to ERC20
        }

        // sets minimum amounts out to 0
        uint256[] memory underlyingBalances = new uint256[](underlyingTokens.length);

        deal(address(pool), address(cellar), sptShares);

        return _createBytesDataToExitSwaapPool(pool, underlyingTokens, underlyingBalances, sptShares);
    }

    function _swaapSafeguardAllowlistSignature(
        address sender,
        uint256 deadline,
        uint256 signerKey,
        bytes32 domainSeparator
    ) internal pure returns (bytes memory signature) {
        bytes32 ALLOWLIST_STRUCT_TYPEHASH = keccak256("AllowlistStruct(address sender,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(ALLOWLIST_STRUCT_TYPEHASH, sender, deadline));
        bytes32 digest = ECDSA.toTypedDataHash(domainSeparator, structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        signature = abi.encodePacked(r, s, v);
    }
}
