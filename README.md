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


## Running tests

1. `git clone https://github.com/kleros/openiico-contract`

2. `cd openiico-contract`

3. `truffle test ./test/IICO.js`

[Truffle](http://truffleframework.com/) should be installed: `npm install -g truffle`