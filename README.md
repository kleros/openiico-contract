# Interactive Coin Offering


This contract implements the Interactive Coin Offering token sale as described in this paper:
https://people.cs.uchicago.edu/~teutsch/papers/ico.pdf

Implementation details and modifications compared to the paper:
- A fixed amount of tokens is sold. This allows more flexibility for the distribution of the remaining tokens (rounds, team tokens which can be preallocated, non-initial sell of some cryptographic assets).
- The valuation pointer is only moved when the sale is over. This greatly reduces the amount of write operations and code complexity. However, at least one party must make one or multiple calls to finalize the sale.
- Buckets are not used as they are not required and increase code complexity.
- The bid submitter must provide the insertion spot. A search of the insertion spot is still done in the contract just in case the one provided was wrong or other bids were added between when the TX got signed and executed, but giving the search starting point greatly lowers gas consumption.
- Automatic withdrawals are only possible at the end of the sale. This decreases code complexity and possible interactions between different parts of the code.
- We put a full bonus, free withdrawal period at the beginning. This allows everyone to have a chance to place bids with full bonus and avoids clogging the network just after the sale starts. Note that at this moment, no information can be taken for granted as parties can withdraw freely.
- Calling the fallback function while sending ETH places a bid with an infinite maximum valuation. This allows buyers who want to buy no matter the price not need to use a specific interface and just send ETH. Without ETH, a call to the fallback function redeems the bids of the caller.

Security notes:
- If the fallback function of the cutoff bid reverts on send. The cutoff bid contributor will not receive its ETH back. It's the responsability of contributors using smart contracts to ensure their fallback functions accept transfers.
- The contract assumes that the owner set appropriate parameters.
- The contract assumes that just after creation, tokens are transfered to the IICO contract and that the owner calls `setToken`.
- The general philosophy is that users are responsible for their actions, interfaces must help them not to make mistakes but it is not the responsability of the contract to do so.
- There is a O(1) griefing factor attack to this contract. However, the griefing factor is small. A user could make a lot of useless bids to make the `finalize` function cost more gas to finish or require calling it multiple times due to gas limit.
The griefing factor is small as the attacker needs to pay gas for storage write operations while the defender only needs to pay for storage read operations (plus a constant amount of storage write operations per `finalize` call).
- Parties calling the contract first need to call `search` to give the starting value of the search. Again, an attacker could make a lot of bids at high gas price in order in order to make a TX fail (due to the search taking more time than the max gas because the insertion point would have been changed by the new bids). But again this is a O(1) griefing factor with a really low griefing factor.

The LevelWhitelistedIICO contract inherits from the IICO contract. It implements a basic KYC where users individual contributions are capped and a reinforced KYC where contributions are not limited.


# Running tests

1. `git clone https://github.com/kleros/openiico-contract`

2. `cd openiico-contract`

3. `truffle test`


# Setting up your own contract (high level)
1. Deploy a token and IICO contract. Note that you can use the same token contract with multiple IICO contracts.
2. Use `Token.mint(IICOContractAddress)` to mint tokens for the IICO contract on the token contract.
3. Use `IICO.setToken(tokenContractAddress)` to set the token on the IICO contract.
4. If you are using the IICO contract with whitelist functionality, you'll also need to call `IICO.setWhitelister(whitelisterAddress)` so the whitelister can add addresses to the whitelist.


# Setting up your own contract (step by step)

This readme assumes that you have some experience with Ethereum, Solidity, Metamask, etc...

In order to test the https://github.com/kleros/openiico Dapp it might be helpful to deploy your own `iico` contract. 

`git clone https://github.com/kleros/openiico-contract`

We are using Kovan, for me the easier way to get some test Kovan Ether is the faucet: https://gitter.im/kovan-testnet/faucet

You paste your ETH address and a bot sends 5 test ETH shortly after.

We will use Metamask and Remix IDE to deploy the contract.

To get all the files in a single run, we will use a [truffle-flattener](https://www.npmjs.com/package/truffle-flattener)

`npm install truffle-flattener -g`

`truffle-flattener contracts/LevelWhitelistedIICO.sol > output.sol`

Now get the contents of `output.sol` and go to https://remix.ethereum.org/

Constructor parameters:

```
uint256 _startTime, 
uint256 _fullBonusLength, 
uint256 _partialWithdrawalLength, 
uint256 _withdrawalLockUpLength, 
uint256 _maxBonus, 
address _beneficiary, 
uint256 _maximumBaseContribution
```


JavaScript hack to get current timestamp: `((+ new Date()) + "").slice(0, -3)`
Converting date to number, then converting number to string, then removing 3 last digits to have Unix epoch time (as opposed to JavaScript milliseconds)

In my instance I will pass the following parameters:

`1525792200, 86400, 86400, 86400, 2E8, "0x85A363699C6864248a6FfCA66e4a1A5cCf9f5567", "5000000000000000000"`

Note that your initial timestamp and duration of particular phases will differ. Also the beneficiary address is most likely to be different :)

Note that `_maxBonus` is expressed in relation to `uint constant BONUS_DIVISOR = 1E9;`

Note that JavaScript handles large numbers different than Solidity and sometimes you need to apply double quotes.

You can see the deployed contract here: https://kovan.etherscan.io/address/0x3311fff00a0b7553f127b5b25397e12cb268f919#code


## Token creation

We have IICO deployed but we don't have the token! We need to create token now...


```
    function setToken(ERC20 _token) public onlyOwner {
        require(address(token) == address(0)); // Make sure the token is not already set.

        token = _token;
        tokensForSale = token.balanceOf(this);
    }
```


We will create `MintableToken` so that we can mint tokens to the crowdsale address - as you can see in the code above, the amount of tokens for sale is equal to the balance.

Let's do this:

```
pragma solidity ^0.4.19;

import 'zeppelin-solidity/contracts/token/ERC20/MintableToken.sol';

contract KlerosCoin is MintableToken {
    string public name = "KLEROS COIN";
    string public symbol = "KLE";
    uint8 public decimals = 18;
}
```

Save this code in `contracts/KlerosCoin.sol` and then `truffle-flattener contracts/KlerosCoin.sol  > output-coin.sol`

Back to Remix to deploy it.

Here it is deployed `KlerosCoin` contract: https://kovan.etherscan.io/address/0xbddc43642eb2b9307e92d7b7e32c31958081ffb8#code


## Setting the token, setting the whitelister

There are many ways how you can interact with smart contracts. Because we were using Remix IDE we should have easy access to the functions.

First, we will start with mint, the beneficiary is the address of the crowdsale

> Total token supply: 1,000,000,000 PNK
> 16% First Round of Token Sale

Source: https://kleros.io/token-sale

The way how decimals, floating point numbers, and everything works this should be the correct number:
`"160000000000000000000000000"`

*(easy to make a mistake, I'm sorry)*

And the beneficiary: `0x3311fff00a0b7553f127b5b25397e12cb268f919` which is the `iico` address

![image](https://github.com/stefek99/openiico-contract/blob/run-your-own/docs/interacting-with-contracts.png?raw=true)

Run the transaction.

Verify on Etherscan minting has succeeded.

![image](https://github.com/stefek99/openiico-contract/blob/run-your-own/docs/reading-contract.png?raw=true)

Now set the token to the `iico`. Again will use Remix IDE.

![image](https://github.com/stefek99/openiico-contract/blob/run-your-own/docs/set-token.png?raw=true)

Now set the whitelister - for simplicity the whitelister will be the same account as owner.

Now add to whitelist. Note that the function expects an array, so even if you add a single guy or lady - use square brackets.

## Verify on the web

Go to: https://openiico.io/

Put the crowdsales address: `0x3311ffF00A0b7553f127b5B25397E12CB268F919` *(while still being logged in to Kovan in Metamask)*

After getting yourself with the tutorial, you can place a first bid. If you are the only bidder, the `0.1 ETH` will give you all the tokens!

![](https://github.com/stefek99/openiico-contract/blob/run-your-own/docs/single-bid-all-the-tokens.png?raw=true)

If you spot any issues go to https://github.com/kleros/openiico report an issue and help us [buidl](https://twitter.com/vitalikbuterin/status/971417459872882690) decentralized future together.
