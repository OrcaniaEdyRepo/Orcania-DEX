// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount) external;

    function transferFrom(address sender, address recipient, uint256 amount) external;
}

interface IDEX {

    event SetLiquidity(address indexed user, address indexed token, uint256 amount, uint256 CFCamount);
    event AddLiquidity(address indexed user, address indexed token, uint256 points);
    event WithdrawLiquidity(address indexed user, address indexed token, uint256 points);
    event Swap(address indexed user, address indexed token, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    event Transfer(address indexed from, address indexed to, address token, uint256 value);
    event Approval(address indexed owner, address indexed spender, address token, uint256 value); 

}

abstract contract OrcaniaMath {

    function add(uint256 num1, uint256 num2) internal view returns(uint256 sum) {
        sum = num1 + num2;
        require(sum > num1, "OVERFLOW");
    }

    function sub(uint256 num1, uint256 num2) internal view returns(uint256 out) {
        out = num1 - num2;
        require(num1 > out, "UNDERFLOW");
    }

    function mul(uint256 num1, uint256 num2) internal view returns(uint256 out) {
        out = num1 * num2;
        require(out / num1 == num2, "OVERFLOW");
    }
    function mul(uint256 num1, uint256 num2, uint256 num3) internal view returns(uint256 out1) {
        uint256 out = num1 * num2;
        require(out / num1 == num2, "OVERFLOW");
        out1 = out * num3;
        require(out1 / out == num3, "OVERFLOW");
    }

}

contract DEX is IDEX, OrcaniaMath{
    
    IERC20 OCA;
    address private OCAaddress;

    //Tokens on the DEX can only provide liqudity in OCA (Token-OCA)
    //The token's OCA balance is recorded in the contract is _tokenOCAbalance, and it's own balance is fetched using token.balanceOf(dex)
    mapping(address => uint256) private _tokenOCAbalance; //OCA this token has as liquidity

    //When providing liqudity, users receive liquidity points of the token they are providing liquidity to
    //Below we record the total points of the token, user's points in this token and others, user's allowance for others to use his points
    //Points act like internal ERC20 tokens in the DEX, so users can transfer them and approve them
    mapping(address/*token*/ => uint256) private _totalPoints;
    mapping(address/*user*/ => mapping(address/*token*/ => uint256)) private _points;//Users liquidity points in this token
    mapping(address/*owner*/ => mapping(address/*spender*/ => mapping(address/*token*/ => uint256/*amount*/))) private _allowances;

    constructor(address OCA_) {
        OCA = IERC20(OCA_);

        OCAaddress = OCA_;
    }

    receive() external payable {}

    //Read Functions ==================================================================================================================================
    function liquidity(address token) external view returns(uint256 tokenOwnBalance, uint256 tokenOCAbalance, uint256 totalPoints) {
        if(token == address(0)) {
            tokenOwnBalance = address(this).balance;
        }
        else {
            tokenOwnBalance = IERC20(token).balanceOf(address(this));
        }
        
        tokenOCAbalance = _tokenOCAbalance[token];
        totalPoints = _totalPoints[token];
    }

    //Write Functions =================================================================================================================================
    function swapTokenForOCA(address token, uint256 amountIn, uint256 minAmountOut, uint256 deadLine) external {
        require(block.timestamp < deadLine, "OUT_OF_TIME");
            
        IERC20(token).transferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = SwapTokenForOCA(token, amountIn);

        require(amountOut >= minAmountOut, "INSUFFICIENT_OUTPUT_AMOUNT");
        OCA.transfer(msg.sender, amountOut);
    } 
    function swapTokenForToken(address token, address tokenIn, uint256 amountIn, uint256 minAmountOut, uint256 deadLine) external {
        require(block.timestamp < deadLine, "OUT_OF_TIME");

        IERC20(token).transferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = SwapTokenForOCA(token, amountIn);
        uint256 amountOut1 = SwapOCAForToken(tokenIn, amountOut);

        require(amountOut1 >= minAmountOut, "INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(tokenIn).transfer(msg.sender, amountOut1);
    }
    function swapTokenForCoin(address token, uint256 amountIn, uint256 minAmountOut, uint256 deadLine) external {
        require(block.timestamp < deadLine, "OUT_OF_TIME");

        IERC20(token).transferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = SwapTokenForOCA(token, amountIn);
        uint256 amountOut1 = SwapOCAForCoin(amountOut);

        require(amountOut1 >= minAmountOut, "INSUFFICIENT_OUTPUT_AMOUNT");

        require(payable(msg.sender).send(amountOut1), "FAILED_TO_SEND_ONE");
    }

    function swapCoinForOCA(uint256 minAmountOut, uint256 deadLine) external payable {
        require(block.timestamp < deadLine, "OUT_OF_TIME");

        uint256 amountOut = SwapCoinForOCA();

        require(amountOut >= minAmountOut, "INSUFFICIENT_OUTPUT_AMOUNT"); 

        OCA.transfer(msg.sender, amountOut);
    }
    function swapCoinForToken(address tokenIn, uint256 minAmountOut, uint256 deadLine) external payable {
        require(block.timestamp < deadLine, "OUT_OF_TIME");

        uint256 amountOut = SwapCoinForOCA();
        uint256 amountOut1 = SwapOCAForToken(tokenIn, amountOut);

        require(amountOut1 >= minAmountOut, "INSUFFICIENT_OUTPUT_AMOUNT");

        IERC20(tokenIn).transfer(msg.sender, amountOut1);
    }

    function swapOCAForToken(address token, uint256 amountIn, uint256 minAmountOut, uint256 deadLine) external {
        require(block.timestamp < deadLine, "OUT_OF_TIME");
            
        OCA.transferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = SwapOCAForToken(token, amountIn);

        require(amountOut >= minAmountOut, "INSUFFICIENT_OUTPUT_AMOUNT");

        IERC20(token).transfer(msg.sender, amountOut);
    }
    function swapOCAForCoin(uint256 amountIn, uint256 minAmountOut, uint256 deadLine) external {
        require(block.timestamp < deadLine, "OUT_OF_TIME");

        OCA.transferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = SwapOCAForCoin(amountIn);

        require(amountOut >= minAmountOut, "INSUFFICIENT_OUTPUT_AMOUNT");

        require(payable(msg.sender).send(amountOut), "FAILED_TO_SEND_ONE");    
    }

    //When setting liquidity of a token for the first time, the amount of points per token-OCA provided is equal to OCAamount
    function setLiquidity(address token, uint256 amount, uint256 OCAamount) external {
        require(amount > 0 && OCAamount > 0, "INSUFFICIENT_AMOUNT");
        require(_totalPoints[token] == 0, "LIQUIDITY_ALREADY_SET");
            
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        OCA.transferFrom(msg.sender, address(this), OCAamount);
        
        uint256 userPoints = (OCAamount * 9999) / 10000; 
        
        _tokenOCAbalance[token] = OCAamount;

        _points[msg.sender][token] = userPoints;
        _points[address(this)][token] = OCAamount - userPoints;
        _totalPoints[token] = OCAamount;
            
        emit SetLiquidity(msg.sender, token, amount, OCAamount);
    }
    function addLiquidity(address token, uint256 amount) external {
        require(amount > 0, "INSUFFICIENT_AMOUNT");
        uint256 totalPoints = _totalPoints[token];
        require(totalPoints > 0, "NO_INITIAL_lIQUIDITY_FOUND");

        uint256 contractTokenBalance = IERC20(token).balanceOf(address(this));
        uint256 neededOCA = mul(_tokenOCAbalance[token], amount) / contractTokenBalance;
        uint256 earnedPoints = mul(totalPoints, amount) / contractTokenBalance;

        require (neededOCA > 0 || earnedPoints > 0, "LOW_LIQUIDITY_ADDITION");

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        OCA.transferFrom(msg.sender, address(this), neededOCA);

        _tokenOCAbalance[token] += neededOCA;

        _totalPoints[token] = add(totalPoints, earnedPoints);
        uint256 userPoints = mul(earnedPoints, 9999) / 10000;

        _points[msg.sender][token] += userPoints;
        _points[address(this)][token] += earnedPoints - userPoints;
        emit AddLiquidity(msg.sender, token, earnedPoints);
    }
    function withdrawLiquidity(address token, uint256 points) external {
        require(points > 0, "INSUFFICIENT_AMOUNT");
        require((_points[msg.sender][token] -= points) <= (uint256(-1) - points), "INSUFFICIENT_BALANCE");

        uint256 totalPoints = _totalPoints[token];
        uint256 tokenAmount = mul(IERC20(token).balanceOf(address(this)), points) / totalPoints;
        uint256 cfcAmount = mul(_tokenOCAbalance[token], points) / totalPoints;
            
        _totalPoints[token] -= points;
            
        _tokenOCAbalance[token] -= cfcAmount;
        
        IERC20(token).transfer(msg.sender, tokenAmount);
        OCA.transfer(msg.sender, cfcAmount);

        emit WithdrawLiquidity(msg.sender, token, points);    
    }

    function setCoinLiquidity(uint256 OCAamount) external payable {
        require(msg.value > 0 && OCAamount > 0, "INSUFFICIENT_AMOUNT");
        require(_totalPoints[address(0)] == 0, "LIQUIDITY_ALREADY_SET");

        OCA.transferFrom(msg.sender, address(this), OCAamount);
        
        uint256 userPoints = (OCAamount * 9999) / 10000; 
        
        _tokenOCAbalance[address(0)] = OCAamount;

        _points[msg.sender][address(0)] = userPoints;
        _points[address(this)][address(0)] = OCAamount - userPoints;
        _totalPoints[address(0)] = OCAamount;
            
        emit SetLiquidity(msg.sender, address(0), msg.value, OCAamount);
    }
    function addCoinLiquidity() external payable {
        require(msg.value > 0, "INSUFFICIENT_AMOUNT");

        require(_totalPoints[address(0)] != 0, "LIQUIDITY_NOT_SET");
        
        uint256 neededOCA = mul(_tokenOCAbalance[address(0)], msg.value) / (address(this).balance - msg.value);
        uint256 earnedPoints = mul(_totalPoints[address(0)], msg.value) / (address(this).balance - msg.value);

        require (neededOCA > 0 && earnedPoints > 0, "LOW_LIQUIDITY-ADDITION");
        OCA.transferFrom(msg.sender, address(this), neededOCA);

        _tokenOCAbalance[address(0)] += neededOCA;

        _totalPoints[address(0)] = add(_totalPoints[address(0)], earnedPoints);
        uint256 userPoints = mul(earnedPoints, 9999) / 10000;

        _points[msg.sender][address(0)] += userPoints;
        _points[address(this)][address(0)] += earnedPoints - userPoints;
            
        emit AddLiquidity(msg.sender, address(0), userPoints);
    }
    function withdrawCoinLiquidity(uint256 points) external  {
        require(points > 0, "INSUFFICIENT_AMOUNT");
        require((_points[msg.sender][address(0)] -= points) <= (uint256(-1) - points), "INSUFFICIENT_BALANCE");

        uint256 totalPoints = _totalPoints[address(0)];
        uint256 tokenAmount = mul(address(this).balance, points) / totalPoints;
        uint256 cfcAmount = mul(_tokenOCAbalance[address(0)], points) / totalPoints;

        _totalPoints[address(0)] -= points;
            
        _tokenOCAbalance[address(0)] -= cfcAmount;

        require(payable(msg.sender).send(tokenAmount), "FAILED_TO_SEND_ONE");
        OCA.transfer(msg.sender, cfcAmount);

        emit WithdrawLiquidity(msg.sender, address(0), points);
    }

    //Points token functionality ======================================================================================================================
    function balanceOf(address user, address token) external view returns(uint256) {return _points[user][token];}

    function allowance(address owner, address spender, address token) external view returns (uint256) {
        return _allowances[owner][spender][token];
    }

    function transferPoints(address receiver, address token, uint256 amount) external {
        require((_points[msg.sender][token] -= amount) <= (uint256(-1) - amount), "INSUFFICIENT_BALANCE");
           
        _points[receiver][token] += amount;

        emit Transfer(msg.sender, receiver, token, amount);
    }

    function transferPointsFrom(address owner, address receiver, address token, uint256 amount) external {
        require((_allowances[owner][msg.sender][token] -= amount) <= (uint256(-1) - amount), "INSUFFICIENT_ALLOWANCE");
        require((_points[owner][token] -= amount) <= (uint256(-1) - amount), "INSUFFICIENT_BALANCE");
            
        _points[receiver][token] += amount;

        emit Transfer(owner, receiver, token, amount);
    }

    function approve(address spender, address token, uint256 amount) external {
        _allowances[msg.sender][spender][token] = amount;
            
        emit Approval(msg.sender, spender, token, amount);
    }

    //Internal Functions===============================================================================================================================

    function SwapTokenForOCA(address token, uint256 amountIn) internal returns(uint256 amountOut) {
        amountOut = mul(amountIn, _tokenOCAbalance[token], 999) / mul( IERC20(token).balanceOf(address(this)), 1000);

        _tokenOCAbalance[token] -= amountOut;

        emit Swap(msg.sender, token, OCAaddress, amountIn, amountOut);
    }

    function SwapOCAForToken(address token, uint256 amountIn) internal returns(uint256 amountOut) {
        amountOut = mul(amountIn, IERC20(token).balanceOf(address(this)), 999) / ((_tokenOCAbalance[token] += amountIn) * 1000);
            
        emit Swap(msg.sender, OCAaddress, token, amountIn, amountOut);
    }

    function SwapCoinForOCA() internal returns(uint256 amountOut) {
        amountOut = (msg.value * _tokenOCAbalance[address(0)] * 999) / (address(this).balance * 1000);

        _tokenOCAbalance[address(0)] -= amountOut;

        emit Swap(msg.sender, address(0), OCAaddress, msg.value, amountOut);
    }

    function SwapOCAForCoin(uint256 amountIn) internal returns(uint256 amountOut) {
        amountOut = (amountIn * address(this).balance * 999) / ((_tokenOCAbalance[address(0)] += amountIn) * 1000);

        emit Swap(msg.sender, OCAaddress, address(0), amountIn, amountOut);
    }

}
