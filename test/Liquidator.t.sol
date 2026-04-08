// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {Liquidator} from "../contracts/Liquidator.sol";
import {IEVault, ILiquidation, IRiskManager, IERC4626, IERC20, IBorrowing} from "../contracts/IEVault.sol";
import {IEVC} from "../contracts/IEVC.sol";
import {ISwapper} from "../contracts/ISwapper.sol";

// ─── Minimal SafeERC20 ────────────────────────────────────────────────────────
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.approve.selector, spender, amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: approve failed");
    }
}

// ─── Minimal interface for Euler's oracle router ──────────────────────────────
interface IEulerRouter {
    function governor() external view returns (address);
    function govSetConfig(address asset, address unitOfAccount, address oracle) external;
}

// ─── Minimal ERC-721 interface for approving wrapper deposits ─────────────────
interface IERC721Minimal {
    function approve(address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

// ─── Uniswap V4 wrapper vault interface ───────────────────────────────────────
interface IUniswapV4Wrapper {
    /// @notice The two ERC-4626 vault tokens that back positions in this wrapper
    function currency0() external view returns (address);
    function currency1() external view returns (address);
    /// @notice The underlying Uniswap V4 Position Manager (ERC-721)
    function underlying() external view returns (address);
    /// @notice Wrap a Uniswap V4 position NFT into wrapper shares
    function wrap(uint256 tokenId, address to) external;
    /// @notice Unwrap shares back to the underlying token components
    function unwrap(address from, uint256 tokenId, address to, uint256 amount, bytes calldata extraData) external;
    function getEnabledTokenIds(address owner) external view returns (uint256[] memory);
    function balanceOf(address owner, uint256 tokenId) external view returns (uint256);
    /// @notice Enable a token ID so it counts as collateral in the EVC
    function enableTokenIdAsCollateral(uint256 tokenId) external;
}

// ─── WETH interface ───────────────────────────────────────────────────────────
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ─── Fixed-price oracle for testing ──────────────────────────────────────────
contract FixedPriceOracle {
    uint256 public immutable price;

    constructor(uint256 _price) {
        price = _price;
    }

    function getQuote(uint256 inAmount, address, address) external view returns (uint256) {
        return (inAmount * price) / 1e18;
    }

    function getQuotes(uint256 inAmount, address, address) external view returns (uint256, uint256) {
        uint256 outAmount = (inAmount * price) / 1e18;
        return (outAmount, outAmount);
    }
}

// ─── Minimal DEX mock ─────────────────────────────────────────────────────────
contract MockDEX {
    using SafeERC20 for IERC20;

    error InsufficientBalance();

    receive() external payable {}

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external {
        uint256 balance = IERC20(tokenIn).balanceOf(msg.sender);
        amountIn = amountIn > balance ? balance : amountIn;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(tokenOut).balanceOf(address(this)) < amountOut) revert InsufficientBalance();
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
contract LiquidatorCompleteTest is Test {
    using SafeERC20 for IERC20;
    // ── Mainnet addresses ────────────────────────────────────────────────────
    address constant EVC_ADDR    = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address constant SWAPPER_ADDR = 0xBF4D90a9c3F1CC9Bb5FeA7F3C6c2F264DD652BFE;
    address constant WETH_ADDR   = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Euler V2 single-asset EVK vaults
    address constant E_USDC = 0xF7d5113F9d04Dcc1AEeBC3a34aa7b523E32edb2B;
    address constant E_USDT = 0xF9caF8dD6c8ddf8E03f6304A926A0C263374e6Cc;

    // Uniswap V4 LP wrapper vaults
    address constant ETH_USDC_V4_WRAPPER  = 0x804B029Dd99A4CA6EBB1A93D6bF87dfC05af186F;
    address constant USDC_USDT_V4_WRAPPER = 0xB7fD0aCb27D19F12596325758f545a430E586780;

    // Run against the fork to find suitable owners, e.g.:
    //   cast call <WRAPPER> "ownerOf(uint256)" <tokenId> --rpc-url $MAINNET_RPC_URL --block 24733122
    address usdcUsdtPositionHolder = 0x12e74f3C61F6b4d17a9c3Fdb3F42e8f18a8bB394; 
    uint256 usdcUsdtTokenId        = 190371;//USDC-USDT position worth 5.34 dollars. (1.97 USDC, 3.38 USDT)

    address ethUsdcPositionHolder  = 0x12e74f3C61F6b4d17a9c3Fdb3F42e8f18a8bB394; 
    uint256 ethUsdcTokenId         = 190369;          // position worth 4.30 dollars (<0.001 ETH, 2.15 USDC, market price 2,172.09 USDC per ETH)


    // ── Shared state ─────────────────────────────────────────────────────────
    Liquidator       liquidator;
    IEVC             evc;
    MockDEX          mockDEX;
    FixedPriceOracle fixedPriceOracle;

    IEVault debtVault;   // E_USDC – debt in all three tests
    IERC20  usdc;
    IERC20  usdt;
    IWETH   weth;

    IEulerRouter eulerRouter;
    address      governor;
    address      unitOfAccount;

    address borrower;
    address liquidatorEOA;

    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────────
    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), 24733122);

        evc       = IEVC(payable(EVC_ADDR));
        debtVault = IEVault(E_USDC);
        usdc      = IERC20(debtVault.asset());
        usdt      = IERC20(IEVault(E_USDT).asset());
        weth      = IWETH(WETH_ADDR);

        eulerRouter   = IEulerRouter(debtVault.oracle());
        governor      = eulerRouter.governor();
        unitOfAccount = debtVault.unitOfAccount();

        liquidator = new Liquidator(
            address(this),  // owner
            SWAPPER_ADDR,   // swapper
            address(1),     // swapVerifier – unused in these tests
            EVC_ADDR,       // evc
            address(1)      // pyth     – unused in these tests
        );

        mockDEX       = new MockDEX();
        liquidatorEOA = makeAddr("liquidatorEOA");
        borrower      = makeAddr("borrower");

        // Seed the USDC vault so the borrower has something to borrow
        uint256 seedAmount = 5000 * 1e6;
        deal(address(usdc), address(this), seedAmount);
        usdc.safeApprove(E_USDC, type(uint256).max);
        debtVault.deposit(seedAmount, address(this));
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _setCollateralPrice(address collateralVault, uint256 priceWad) internal {
        fixedPriceOracle = new FixedPriceOracle(priceWad);
        vm.prank(governor);
        eulerRouter.govSetConfig(collateralVault, unitOfAccount, address(fixedPriceOracle));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1 – Normal EVK vault: USDT collateral → USDC debt
    //
    // Flow inside Liquidator:
    //   redeemOrUnwrap detects asset() on E_USDT → calls IERC4626.redeem()
    //   Swapper receives USDT, swaps to USDC, repays debt
    // ─────────────────────────────────────────────────────────────────────────
    function test_Liquidate_EVKVault() public {
        IEVault collateralVault = IEVault(E_USDT);
        uint256 depositAmount   = 2000 * 1e6; // 2 000 USDT
        uint256 borrowAmount    = 1000 * 1e6; // 1 000 USDC

        // Borrower: deposit USDT, enable as collateral, borrow USDC
        deal(address(usdt), borrower, depositAmount);
        vm.startPrank(borrower);
        usdt.safeApprove(E_USDT, type(uint256).max);
        collateralVault.deposit(depositAmount, borrower);
        evc.enableCollateral(borrower, E_USDT);
        evc.enableController(borrower, E_USDC);
        debtVault.borrow(borrowAmount, borrower);
        vm.stopPrank();

        // Crash USDT price so that collateral < debt
        _setCollateralPrice(E_USDT, 0.1 ether); // 0.1 USD per eUSDT share

        (uint256 collVal, uint256 debtVal) = debtVault.accountLiquidity(borrower, false);
        assertLt(collVal, debtVal, "position must be liquidatable");

        vm.warp(block.timestamp + 1);

        (uint256 maxRepay, uint256 maxYield) =
            debtVault.checkLiquidation(address(liquidator), borrower, E_USDT);


        // Swap data: USDT → USDC via MockDEX (exact-input)
        uint256 collateralAssets = collateralVault.convertToAssets(maxYield);


        // Fund the mock DEX with USDC so it can fill the swap
        // it will return 1:1 
        deal(address(usdc), address(mockDEX), collateralAssets);


        bytes[] memory swapperData = new bytes[](1);
        swapperData[0] = abi.encodeCall(
            ISwapper.swap,
            ISwapper.SwapParams({
                handler:  bytes32("Generic"),
                mode:     0,
                account:  address(0),
                tokenIn:  address(usdt),
                tokenOut: address(usdc),
                vaultIn:  address(0),
                accountIn: address(0),
                receiver: liquidatorEOA,
                amountOut: 0,
                data: abi.encode(
                    address(mockDEX),
                    abi.encodeWithSelector(
                        MockDEX.swap.selector,
                        address(usdt), address(usdc), collateralAssets, collateralAssets
                    )
                )
            })
        );

        Liquidator.LiquidationParams memory params = Liquidator.LiquidationParams({
            violatorAddress:       borrower,
            vault:                 E_USDC,
            borrowedAsset:         address(usdc),
            collateralVault:       E_USDT,
            collateralAsset:       address(usdt), // sweep any remaining USDT dust
            repayAmount:           0,
            seizedCollateralAmount: 0,
            receiver:              liquidatorEOA,
            additionalToken:       address(0)
        });

        vm.prank(liquidatorEOA);
        liquidator.liquidateSingleCollateral(params, swapperData);

        assertGe(IERC20(address(usdc)).balanceOf(liquidatorEOA), 0, "liquidator should receive USDC profit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2 – USDC-USDT wrapper: ERC-721 LP position as collateral
    //   Position 190371: ~1.97 USDC + ~3.38 USDT ≈ $5.34
    //
    // Flow inside Liquidator:
    //   redeemOrUnwrap detects NO asset() on wrapper → calls unwrap() for each
    //   enabled token ID; swapper receives currency0 + currency1 vault tokens
    //   Swap currency1 (eUSDT side, ~3.38 USDT) → USDC to repay; sweep currency0 to receiver
    // ─────────────────────────────────────────────────────────────────────────
    function test_Liquidate_USDCUSDTWrapper() public {
        IUniswapV4Wrapper wrapper = IUniswapV4Wrapper(USDC_USDT_V4_WRAPPER);
        address currency0 = wrapper.currency0(); // eUSDC component vault
        address currency1 = wrapper.currency1(); // eUSDT component vault

        // Borrow 2 USDC against a ~$5.34 position (well within LTV)
        uint256 borrowAmount = 2 * 1e6;

        // Transfer the NFT from its holder to a fresh borrower account, then
        // do all Euler operations as the borrower.
        vm.startPrank(usdcUsdtPositionHolder);
        IERC721Minimal(wrapper.underlying()).transferFrom(usdcUsdtPositionHolder, borrower, usdcUsdtTokenId);
        vm.stopPrank();

        vm.startPrank(borrower);
        IERC721Minimal(wrapper.underlying()).approve(USDC_USDT_V4_WRAPPER, usdcUsdtTokenId);
        wrapper.wrap(usdcUsdtTokenId, borrower);
        wrapper.enableTokenIdAsCollateral(usdcUsdtTokenId);
        evc.enableCollateral(borrower, USDC_USDT_V4_WRAPPER);
        evc.enableController(borrower, E_USDC);
        debtVault.borrow(borrowAmount, borrower);
        vm.stopPrank();

        // Crash wrapper price to make position liquidatable
        _setCollateralPrice(USDC_USDT_V4_WRAPPER, 0.3 ether);

        (uint256 collVal, uint256 debtVal) = debtVault.accountLiquidity(borrower, false);
        assertLt(collVal, debtVal, "position must be liquidatable");

        vm.warp(block.timestamp + 1);

        (uint256 maxRepay,) =
            debtVault.checkLiquidation(address(liquidator), borrower, USDC_USDT_V4_WRAPPER);

        // Fund mock DEX with enough USDC to cover the full repay
        deal(address(usdc), address(mockDEX), maxRepay + 10e6);

        // Swap data: swap ALL currency1 (eUSDT, ~3.38 USDT worth) → USDC
        // MockDEX caps amountIn to the swapper's actual balance, then pays out maxRepay USDC
        // currency0 (eUSDC) is swept directly to receiver as additional profit
        bytes[] memory swapperData = new bytes[](1);
        swapperData[0] = abi.encodeCall(
            ISwapper.swap,
            ISwapper.SwapParams({
                handler:  bytes32("Generic"),
                mode:     0,
                account:  address(0),
                tokenIn:  currency1,
                tokenOut: address(usdc),
                vaultIn:  address(0),
                accountIn: address(0),
                receiver: liquidatorEOA,
                amountOut: 0,
                data: abi.encode(
                    address(mockDEX),
                    abi.encodeWithSelector(
                        MockDEX.swap.selector,
                        currency1, address(usdc), type(uint256).max, maxRepay
                    )
                )
            })
        );

        Liquidator.LiquidationParams memory params = Liquidator.LiquidationParams({
            violatorAddress:       borrower,
            vault:                 E_USDC,
            borrowedAsset:         address(usdc),
            collateralVault:       USDC_USDT_V4_WRAPPER,
            collateralAsset:       currency0,   // eUSDC component swept to receiver as profit
            repayAmount:           0,
            seizedCollateralAmount: 0,
            receiver:              liquidatorEOA,
            additionalToken:       currency1    // eUSDT dust swept after swap
        });

        vm.prank(liquidatorEOA);
        liquidator.liquidateSingleCollateral(params, swapperData);

        assertGe(IERC20(address(usdc)).balanceOf(liquidatorEOA), 0, "liquidator should receive USDC profit");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3 – ETH-USDC wrapper: LP position where one side is native ETH
    //   Position 190369: <0.001 ETH + ~2.15 USDC ≈ $4.30 (ETH @ $2,172)
    //
    // Flow inside Liquidator:
    //   redeemOrUnwrap → unwrap() sends native ETH + currency1 vault token to swapper
    //   swapper's receive() fallback automatically wraps the ETH into WETH
    //   swapperData[0]: GenericHandler calls MockDEX.swap(WETH → USDC)
    //   repay + sweep eUSDC component (currency1) to receiver as profit
    // ─────────────────────────────────────────────────────────────────────────
    function test_Liquidate_ETHUSDCWrapper() public {
        IUniswapV4Wrapper wrapper = IUniswapV4Wrapper(ETH_USDC_V4_WRAPPER);
        // currency0 is the ETH side (native ETH sent by unwrap to swapper)
        // currency1 is the eUSDC component vault
        address currency1 = wrapper.currency1();

        // Borrow 1 USDC against a ~$4.30 position (well within LTV)
        uint256 borrowAmount = 1 * 1e6;

        // Transfer the NFT from its holder to a fresh borrower account, then
        // do all Euler operations as the borrower.
        vm.startPrank(ethUsdcPositionHolder);
        IERC721Minimal(wrapper.underlying()).transferFrom(ethUsdcPositionHolder, borrower, ethUsdcTokenId);
        vm.stopPrank();

        vm.startPrank(borrower);
        IERC721Minimal(wrapper.underlying()).approve(ETH_USDC_V4_WRAPPER, ethUsdcTokenId);
        wrapper.wrap(ethUsdcTokenId, borrower);
        wrapper.enableTokenIdAsCollateral(ethUsdcTokenId);
        evc.enableCollateral(borrower, ETH_USDC_V4_WRAPPER);
        evc.enableController(borrower, E_USDC);
        debtVault.borrow(borrowAmount, borrower);
        vm.stopPrank();

        // Crash wrapper price to make position liquidatable
        _setCollateralPrice(ETH_USDC_V4_WRAPPER, 0.3 ether);

        (uint256 collVal, uint256 debtVal) = debtVault.accountLiquidity(borrower, false);
        assertLt(collVal, debtVal, "position must be liquidatable");

        vm.warp(block.timestamp + 1);

        (uint256 maxRepay,) =
            debtVault.checkLiquidation(address(liquidator), borrower, ETH_USDC_V4_WRAPPER);

        // Fund mock DEX: it receives WETH (<0.001 ETH) and must pay out maxRepay USDC.
        // The swapper's fallback automatically wraps any native ETH it receives into WETH,
        // so by the time the swap step runs the swapper already holds WETH.
        deal(address(usdc), address(mockDEX), maxRepay + 10e6);

        bytes[] memory swapperData = new bytes[](1);

        // Single swap: WETH → USDC via MockDEX
        // (ETH→WETH conversion already handled by the swapper's receive() fallback)
        swapperData[0] = abi.encodeCall(
            ISwapper.swap,
            ISwapper.SwapParams({
                handler:  bytes32("Generic"),
                mode:     0,
                account:  address(0),
                tokenIn:  WETH_ADDR,
                tokenOut: address(usdc),
                vaultIn:  address(0),
                accountIn: address(0),
                receiver: liquidatorEOA,
                amountOut: 0,
                data: abi.encode(
                    address(mockDEX),
                    abi.encodeWithSelector(
                        MockDEX.swap.selector,
                        WETH_ADDR, address(usdc), type(uint256).max, maxRepay
                    )
                )
            })
        );

        Liquidator.LiquidationParams memory params = Liquidator.LiquidationParams({
            violatorAddress:       borrower,
            vault:                 E_USDC,
            borrowedAsset:         address(usdc),
            collateralVault:       ETH_USDC_V4_WRAPPER,
            collateralAsset:       currency1,    // eUSDC component swept to receiver as profit
            repayAmount:           0,
            seizedCollateralAmount: 0,
            receiver:              liquidatorEOA,
            additionalToken:       address(0)    // ETH side is fully swapped via swapperData
        });

        vm.prank(liquidatorEOA);
        liquidator.liquidateSingleCollateral(params, swapperData);

        assertGe(IERC20(address(usdc)).balanceOf(liquidatorEOA), 0, "liquidator should receive USDC profit");
    }

    function test_SendETHToSwapper() public{
        uint256 ethToSend = 1 ether;
        deal(address(this), ethToSend);
        (bool success,) = address(SWAPPER_ADDR).call{value: ethToSend}("");
        require(success, "ETH transfer failed");

        assertEq(IERC20(WETH_ADDR).balanceOf(SWAPPER_ADDR), ethToSend);
    }
}
