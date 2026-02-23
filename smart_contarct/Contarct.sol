// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// ============================================================
//  INTERFACES
// ============================================================

// Uniswap V3 SwapRouter
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24  fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable returns (uint256 amountOut);

    struct ExactInputParams {
        bytes   path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params)
        external payable returns (uint256 amountOut);
}

// Aave V3 Pool
interface IAavePool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16  referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);

    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode, // 1=stable, 2=variable
        uint16  referralCode,
        address onBehalfOf
    ) external;

    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external returns (uint256);

    function getUserAccountData(address user)
        external view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// Simple Bridge Interface (LayerZero / Optimism standard bridge)
interface IBridge {
    function bridge(
        address token,
        uint256 amount,
        uint32  destinationChainId,
        address recipient,
        bytes   calldata extraData
    ) external payable;
}

// ============================================================
//  MAIN CONTRACT
// ============================================================

/**
 * @title  DeFiHub
 * @notice Unified contract untuk Swap, Bridge, Supply, Borrow, Repay
 *         di Ethereum Sepolia Testnet
 * @dev    Gunakan hanya di testnet!
 */
contract DeFiHub is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── State Variables ──────────────────────────────────────
    ISwapRouter public swapRouter;
    IAavePool   public aavePool;
    IBridge     public bridge;

    uint16 public constant REFERRAL_CODE = 0;

    // ── Events ───────────────────────────────────────────────
    event Swapped(
        address indexed user,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event Bridged(
        address indexed user,
        address token,
        uint256 amount,
        uint32  destinationChainId,
        address recipient
    );
    event Supplied(address indexed user, address token, uint256 amount);
    event Withdrawn(address indexed user, address token, uint256 amount);
    event Borrowed(address indexed user, address token, uint256 amount, uint256 rateMode);
    event Repaid(address indexed user, address token, uint256 amount, uint256 rateMode);

    // ── Errors ───────────────────────────────────────────────
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientBalance();
    error InvalidRateMode();

    // ── Constructor ──────────────────────────────────────────
    constructor(
        address _swapRouter,
        address _aavePool,
        address _bridge
    ) Ownable(msg.sender) {
        if (_swapRouter == address(0) || _aavePool == address(0))
            revert ZeroAddress();

        swapRouter = ISwapRouter(_swapRouter);
        aavePool   = IAavePool(_aavePool);

        // Bridge bisa opsional (address(0) jika tidak dipakai)
        if (_bridge != address(0)) {
            bridge = IBridge(_bridge);
        }
    }

    // ============================================================
    //  SWAP — Uniswap V3
    // ============================================================

    /**
     * @notice Swap token menggunakan Uniswap V3 (single hop)
     * @param tokenIn        Alamat token yang ingin di-swap
     * @param tokenOut       Alamat token yang ingin diterima
     * @param fee            Fee tier (500=0.05%, 3000=0.3%, 10000=1%)
     * @param amountIn       Jumlah token yang akan di-swap
     * @param amountOutMin   Minimum token yang harus diterima (slippage protection)
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint24  fee,
        uint256 amountIn,
        uint256 amountOutMin
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0)        revert ZeroAmount();
        if (tokenIn  == address(0) || tokenOut == address(0)) revert ZeroAddress();

        // Tarik token dari user ke contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Approve ke SwapRouter
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);

        // Eksekusi swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn:           tokenIn,
                tokenOut:          tokenOut,
                fee:               fee,
                recipient:         msg.sender,
                deadline:          block.timestamp + 300,
                amountIn:          amountIn,
                amountOutMinimum:  amountOutMin,
                sqrtPriceLimitX96: 0
            });

        amountOut = swapRouter.exactInputSingle(params);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /**
     * @notice Swap multi-hop (contoh: USDC → WETH → DAI)
     * @param path           Encoded path (token + fee + token + fee + token ...)
     * @param amountIn       Jumlah token masuk
     * @param amountOutMin   Minimum token keluar
     */
    function swapMultiHop(
        bytes   calldata path,
        uint256 amountIn,
        uint256 amountOutMin
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        // Decode tokenIn dari path (20 bytes pertama)
        address tokenIn;
        assembly { tokenIn := shr(96, calldataload(path.offset)) }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path:             path,
            recipient:        msg.sender,
            deadline:         block.timestamp + 300,
            amountIn:         amountIn,
            amountOutMinimum: amountOutMin
        });

        amountOut = swapRouter.exactInput(params);
        emit Swapped(msg.sender, tokenIn, address(0), amountIn, amountOut);
    }

    // ============================================================
    //  BRIDGE
    // ============================================================

    /**
     * @notice Bridge token ke chain lain
     * @param token              Alamat token yang akan di-bridge
     * @param amount             Jumlah token
     * @param destinationChainId Chain ID tujuan
     * @param recipient          Penerima di chain tujuan
     * @param extraData          Data tambahan (opsional, tergantung bridge protocol)
     */
    function bridgeTokens(
        address token,
        uint256 amount,
        uint32  destinationChainId,
        address recipient,
        bytes   calldata extraData
    ) external payable nonReentrant {
        if (amount    == 0)          revert ZeroAmount();
        if (token     == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        require(address(bridge) != address(0), "Bridge not configured");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(address(bridge), amount);

        bridge.bridge{value: msg.value}(
            token,
            amount,
            destinationChainId,
            recipient,
            extraData
        );

        emit Bridged(msg.sender, token, amount, destinationChainId, recipient);
    }

    // ============================================================
    //  SUPPLY (Aave V3)
    // ============================================================

    /**
     * @notice Supply/deposit token ke Aave V3 sebagai collateral
     * @param token   Alamat token yang akan di-supply
     * @param amount  Jumlah token
     */
    function supply(address token, uint256 amount) external nonReentrant {
        if (amount == 0)          revert ZeroAmount();
        if (token  == address(0)) revert ZeroAddress();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(address(aavePool), amount);

        aavePool.supply(token, amount, msg.sender, REFERRAL_CODE);

        emit Supplied(msg.sender, token, amount);
    }

    /**
     * @notice Withdraw token dari Aave V3
     * @param token   Alamat token yang akan di-withdraw
     * @param amount  Jumlah token (gunakan type(uint256).max untuk semua)
     */
    function withdraw(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert ZeroAddress();

        // aToken harus di-approve ke pool terlebih dahulu
        // User perlu approve aToken ke contract ini sebelum memanggil fungsi ini
        uint256 withdrawn = aavePool.withdraw(token, amount, msg.sender);

        emit Withdrawn(msg.sender, token, withdrawn);
    }

    // ============================================================
    //  BORROW (Aave V3)
    // ============================================================

    /**
     * @notice Borrow token dari Aave V3
     * @param token        Alamat token yang ingin dipinjam
     * @param amount       Jumlah yang dipinjam
     * @param rateMode     1 = Stable Rate, 2 = Variable Rate
     */
    function borrow(
        address token,
        uint256 amount,
        uint256 rateMode
    ) external nonReentrant {
        if (amount == 0)          revert ZeroAmount();
        if (token  == address(0)) revert ZeroAddress();
        if (rateMode != 1 && rateMode != 2) revert InvalidRateMode();

        // User harus sudah menyetujui credit delegation jika borrowing atas nama contract
        aavePool.borrow(token, amount, rateMode, REFERRAL_CODE, msg.sender);

        emit Borrowed(msg.sender, token, amount, rateMode);
    }

    // ============================================================
    //  REPAY (Aave V3)
    // ============================================================

    /**
     * @notice Repay pinjaman ke Aave V3
     * @param token      Alamat token yang akan dibayar
     * @param amount     Jumlah yang dibayar (type(uint256).max = bayar semua)
     * @param rateMode   1 = Stable Rate, 2 = Variable Rate
     */
    function repay(
        address token,
        uint256 amount,
        uint256 rateMode
    ) external nonReentrant returns (uint256 repaid) {
        if (token == address(0)) revert ZeroAddress();
        if (rateMode != 1 && rateMode != 2) revert InvalidRateMode();

        uint256 actualAmount = (amount == type(uint256).max)
            ? IERC20(token).balanceOf(msg.sender)
            : amount;

        if (actualAmount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), actualAmount);
        IERC20(token).forceApprove(address(aavePool), actualAmount);

        repaid = aavePool.repay(token, actualAmount, rateMode, msg.sender);

        // Kembalikan sisa jika ada (misal saat repay semua)
        if (actualAmount > repaid) {
            IERC20(token).safeTransfer(msg.sender, actualAmount - repaid);
        }

        emit Repaid(msg.sender, token, repaid, rateMode);
    }

    // ============================================================
    //  VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Lihat data akun user di Aave V3
     */
    function getUserAaveData(address user)
        external view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return aavePool.getUserAccountData(user);
    }

    // ============================================================
    //  ADMIN FUNCTIONS
    // ============================================================

    function setSwapRouter(address _swapRouter) external onlyOwner {
        if (_swapRouter == address(0)) revert ZeroAddress();
        swapRouter = ISwapRouter(_swapRouter);
    }

    function setAavePool(address _aavePool) external onlyOwner {
        if (_aavePool == address(0)) revert ZeroAddress();
        aavePool = IAavePool(_aavePool);
    }

    function setBridge(address _bridge) external onlyOwner {
        bridge = IBridge(_bridge);
    }

    /**
     * @notice Rescue token yang tersangkut di contract
     */
    function rescueToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }

    receive() external payable {}
    fallback() external payable {}
}