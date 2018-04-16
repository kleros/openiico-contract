/** @title Interactive Coin Offering
 *  @author Clément Lesaege - <clement@lesaege.com>
 */

pragma solidity ^0.4.18;

import "zeppelin-solidity/contracts/token/ERC20/ERC20.sol";

/** @title Interactive Coin Offering
 *  This contract implements the Interactive Coin Offering token sale as described in this paper:
 *  https://people.cs.uchicago.edu/~teutsch/papers/ico.pdf
 *  Modifications compared to the paper:
 *  -A fix amount of tokens is sold. This allows more flexibility for the distribution of the remaining tokens (rounds, team tokens which can be preallocated, non-initial sell of some cryptographic assets).
 *  -The pointer is only moved when the sale is over. This greatly reduces the amount of write operations and code complexity. However, at least one party must make one or multiple calls to finalize the sale.
 *  -Buckets are not used as they are not required and increase code complexity.
 *  -The bid submitter must provide the insertion spot. A search of the insertion spot is still done in the contract, but giving the search starting point greatly lowers gas consumption. The search is still required as the correct insertion spot can change before a TX is signed and its execution.
 *  -Automatic withdrawals are only possible at the end of the sale. This decreases code complexity and possible interactions between different parts of the code.
 *  -We put a full bonus, free withdrawal period at the beginning. This allows everyone to have a chance to place bids with full bonus and avoid clogging the network just after the sale starts. Note that at this moment, no information can be taken from granted as parties can withdraw freely.
 *  -Calling the fallback function while sending ETH place a bid with an infinite maximum valuation. This allows buyers who want to buy no matter the price not to need to use a specific interface and just send ETH. Without ETH, a call to the fallback function redeems the bids of the caller.
 */
contract IICO {

    /* *** General *** */
    address owner;       // The one setting up the contract.
    address beneficiary; // The address which will get the funds.

    /* *** Bid *** */
    uint constant HEAD = 0;            // Minimum value used for both the maxVal and bidID of the head of the linked list.
    uint constant TAIL = uint(-1);     // Maximum value used for both the maxVal and bidID of the tail of the linked list.
    uint constant INFINITY = uint(-2); // A value so high that a bid using it is guaranteed to succeed. Still lower than TAIL to be placed before TAIL.
    // A bid to buy tokens as long as the personal maximum valuation is not exceeded.
    // Bids are in a sorted doubly linked list.
    // They are sorted in ascending order by (maxVal,bidID) where bidID is the ID and index of the bid in the mapping.
    // The list contains two artificial bids HEAD and TAIL having respectively the minimum and maximum bidID and maxVal.
    struct Bid {
        /* *** Linked List Members *** */
        uint prev;            // bidID of the previous element.
        uint next;            // bidID of the next element.
        /* ***     Bid Members     *** */
        uint maxVal;          // Maximum valuation in wei beyond which the contributor prefers refund.
        uint contrib;         // Contribution in wei.
        uint bonus;           // The bonus expressed in 1/BONUS_DIVISOR.
        address contributor;  // The contributor which placed the bid.
        bool withdrawn;       // True if the bid has been withdrawn.
        bool redeemed;        // True if the ETH or tokens has been redeemed.
    }
    mapping (uint => Bid) public bids; // Map bidID to bid.
    mapping (address => uint[]) public contributorBidIDs; // Map contributor to a list of its bid ID.
    uint public lastBidID = 0; // The last bidID not accounting TAIL.

    /* *** Sale parameters *** */
    uint public startTime;                      // When the sale starts.
    uint public endFullBonusTime;               // When the full bonus ends.
    uint public withdrawalLockTime;             // When the contributors can't withdraw their bids anymore.
    uint public endTime;                        // When the sale ends.
    ERC20 public token;                         // The token which is sold.
    uint public tokensForSale;                  // The amount of tokens which will be sold.
    uint public maxBonus;                       // The maximum bonus expressed in 1/BONUS_DIVISOR.
    uint constant BONUS_DIVISOR = 1E9;          // The quantity we need to divide by to normalize the bonus.

    /* *** Finalization variables *** */
    bool public finalized;                 // True when the cutting bid has been found. The following variables are final only after finalized==true.
    uint public cutOffBidID = TAIL;        // The last accepted bid. All bids after it are accepted.
    uint public sumAcceptedContrib;        // The sum of accepted contributions.
    uint public sumAcceptedVirtualContrib; // The sum of virtual (taking into account bonuses) contributions.

    modifier onlyOwner{ require(owner == msg.sender); _; }

    /* *** Functions Modifying the state *** */

    /** @dev Constructor. First contract set up (tokens will also need to be transfered to the contract and then setToken to be called to finish the setup).
     *  @param _startTime Time the sale will start in Unix Timestamp.
     *  @param _fullBonusLength Amount of seconds the sale lasts in the full bonus period.
     *  @param _partialWithdrawalLength Amount of seconds the sale lasts in the partial withdrawal period.
     *  @param _withdrawalLockUpLength Amount of seconds the sale lasts in the withdrawal lockup period.
     *  @param _maxBonus The maximum bonus. Will be normalized by BONUS_DIVISOR. For example for a 20% bonus, _maxBonus must be 0.2 * BONUS_DIVISOR.
     */
    function IICO(uint _startTime, uint _fullBonusLength, uint _partialWithdrawalLength, uint _withdrawalLockUpLength, uint _maxBonus) public {
        owner = msg.sender;
        startTime = _startTime;
        endFullBonusTime = startTime + _fullBonusLength;
        withdrawalLockTime = endFullBonusTime + _partialWithdrawalLength;
        endTime = withdrawalLockTime + _withdrawalLockUpLength;
        maxBonus = _maxBonus;

        // Add the virtual bids. This simplifies other functions.
        bids[HEAD] = Bid({
            prev: TAIL,
            next: TAIL,
            maxVal: HEAD,
            contrib: 0,
            bonus: 0,
            contributor: 0x0,
            withdrawn: false,
            redeemed: false
        });
        bids[TAIL] = Bid({
            prev: HEAD,
            next: HEAD,
            maxVal: TAIL,
            contrib: 0,
            bonus: 0,
            contributor: 0x0,
            withdrawn: false,
            redeemed: false
        });
    }

    /** @dev Set the token. Must only be called after the IICO contract receive the tokens to be sold.
     *  @param _token The token to be sold.
     */
    function setToken(ERC20 _token) public onlyOwner {
        require(address(token) == 0x0);

        token = _token;
        tokensForSale = token.balanceOf(this);
    }

    /** @dev Submit a bid. The caller must give the exact position the bid must be inserted in the list.
     *  In practice use searchAndBid to avoid the position being incorrect due a new bid being inserted changing the position the bid must be inserted.
     *  @param _maxVal The maximum valuation given by the contributor. If the amount raised is higher, the bid is cancelled and the contributor refunded because it prefers refund instead of this level of dilution. To buy no matter what, use INFINITY.
     *  @param _next The bidID of next bid of the bid which will inserted.
     */
    function submitBid(uint _maxVal, uint _next) public payable {
        Bid storage nextBid = bids[_next];
        uint prev = nextBid.prev;
        Bid storage prevBid = bids[prev];
        require(_maxVal >= prevBid.maxVal && _maxVal < nextBid.maxVal); // The new bid maxVal is higher than the previous and strictly lower than the next.
        require(now >= startTime && now < endTime); // Check the bids are open.

        ++lastBidID; // Increment the lastBidID. It will be the one of the bid which will be inserted.
        // Update the pointers of neighboring bids.
        prevBid.next = lastBidID;
        nextBid.prev = lastBidID;

        // Insert the bid.
        bids[lastBidID] = Bid({
            prev: prev,
            next: _next,
            maxVal: _maxVal,
            contrib: msg.value,
            bonus: bonus(),
            contributor: msg.sender,
            withdrawn: false,
            redeemed: false
        });

        // Add the bid to the list of bids by this contributor.
        contributorBidIDs[msg.sender].push(lastBidID);
    }


    /** @dev Search the correct insertion spot and submit a bid.
     *  This function is O(n), where n is the amount of bids between the initial search position and the insertion position.
     *  The UI must first call search to find the best point to start the search and consume the least amount of gas.
     *  Using this function instead of calling submitBid directly prevents it to fail in the case that new bids would be added before the transaction is executed.
     *  @param _maxVal The maximum valuation given by the contributor. If the amount raised is higher, the bid is cancelled and the contributor refunded because it prefers refund instead of this level of dilution. To buy no matter what, use INFINITY.
     *  @param _next The bidID of next bid of the bid which will inserted.
     */
    function searchAndBid(uint _maxVal, uint _next) public payable {
        submitBid(_maxVal, search(_maxVal,_next));
    }

    /** @dev Withdraw a bid. Can only be called before the end of the withdrawal lock.
     *  Withdrawing a bid divides the bonus by 3.
     *  For the automatic withdrawal, use the redeem function.
     *  @param _bidID ID of the bid to withdraw.
     */
    function withdraw(uint _bidID) public {
        Bid storage bid = bids[_bidID];
        require(msg.sender == bid.contributor);
        require(now < withdrawalLockTime);
        require(!bid.withdrawn);

        bid.withdrawn = true;

        // Before endFullBonusTime, everything is refunded. Otherwise an amount decreasing linearly from endFullBonusTime to withdrawalLockTime.
        uint refund = (now < endFullBonusTime) ? bid.contrib : (bid.contrib * (withdrawalLockTime - now)) / (withdrawalLockTime - endFullBonusTime);
        assert(refund <= bid.contrib); // Make sure that we don't refund more than the contribution. Would a bug arise, we prefer blocking withdrawal than letting someone steal money.
        bid.contrib -= refund;
        bid.bonus /= 3; // Divide the bonus by 3.

        msg.sender.transfer(refund);
    }

    /** @dev Finalize by finding the cut-off bid.
     *  Since the amount of bids is not bounded, this function may have to be called multiple times.
     *  The function is in O(min(n,_maxIt)) where n is the amount of bids. In total it will perform O(n) computations, possibly in multiple calls.
     *  Each call only has a O(1) storage write operations.
     *  @param _maxIt The maximum amount of bids to go through. This value must be set in order to not exceed the gas limit.
     */
    function finalize(uint _maxIt) public {
        require(now >= endTime);
        require(!finalized);

        // Make local copies of the finalization variables in order to avoid modifying storage in order to save gas.
        uint localCutOffBidID = cutOffBidID;
        uint localSumAcceptedContrib = sumAcceptedContrib;
        uint localSumAcceptedVirtualContrib = sumAcceptedVirtualContrib;

        // Search for the cut-off while counting the contributions.
        for (uint it = 0; it < _maxIt && !finalized; ++it) {
            Bid storage bid = bids[localCutOffBidID];
            if (bid.contrib+localSumAcceptedContrib < bid.maxVal) { // We haven't found the cut-off yet.
                localSumAcceptedContrib        += bid.contrib;
                localSumAcceptedVirtualContrib += bid.contrib + (bid.contrib * bid.bonus) / BONUS_DIVISOR;
                localCutOffBidID = bid.prev; // Go to previous bid.
            } else { // We found the cut-off. This bid will be taken partially.
                finalized = true;
                uint contribCutOff = bid.maxVal >= localSumAcceptedContrib ? bid.maxVal - localSumAcceptedContrib : 0; // The contribution of the cut-off bid. The amount which remains to go to the maximum valuation of the cut-off bid if any.
                contribCutOff = contribCutOff < bid.contrib ? contribCutOff : bid.contrib; // The contribution can be at max the one given by the contributor. This line should not be required but is added as an extra security measure.
                bid.contributor.send(bid.contrib-contribCutOff); // Send the non-accepted part. Use of send in order not to block in case the contributor fallback would revert.
                bid.contrib = contribCutOff; // Update the contribution value.
                localSumAcceptedContrib += bid.contrib;
                localSumAcceptedVirtualContrib += bid.contrib + (bid.contrib * bid.bonus) / BONUS_DIVISOR;
                beneficiary.send(localSumAcceptedContrib); // Use of send in order not to allow the beneficiary to block the finalization.
            }
        }

        // Update storage.
        cutOffBidID = localCutOffBidID;
        sumAcceptedContrib = localSumAcceptedContrib;
        sumAcceptedVirtualContrib = localSumAcceptedVirtualContrib;
    }

    /** @dev Redeem a bid. If the bid is accepted, send the tokens, otherwise send the ethers back.
     *  Note that anyone can call this function, not only the party which made the bid.
     *  @param _bidID ID of the bid to withdraw.
     */
    function redeem(uint _bidID) public {
        Bid storage bid = bids[_bidID];
        Bid storage cutOffBid = bids[cutOffBidID];
        require(finalized);
        require(!bid.redeemed);

        bid.redeemed=true;
        if (bid.maxVal > cutOffBid.maxVal || (bid.maxVal == cutOffBid.maxVal && _bidID >= cutOffBidID)) // Give tokens if the bid is accepted.
            token.transfer(bid.contributor, (tokensForSale * (bid.contrib + (bid.contrib * bid.bonus) / BONUS_DIVISOR)) / sumAcceptedVirtualContrib);
        else                                                                                      // Reimburse otherwise.
            bid.contributor.transfer(bid.contrib);
    }

    /** @dev Fallback. Make a bid if ETH are sent. Redeem all the bids of the contributor otherwise.
     *  This allows users to bid and get their tokens back using only send operations.
     */
    function () public payable {
        if (msg.value != 0 && now >= startTime && now < endTime) // Make some bid with an infinite maxVal if some ETH were sent.
            submitBid(INFINITY,TAIL);
        else if (msg.value == 0 && finalized)                    // Redeem all the non-already redeemed bids if no ETH were sent.
            for (uint i = 0; i < contributorBidIDs[msg.sender].length; ++i)
                if (!bids[contributorBidIDs[msg.sender][i]].redeemed)
                    redeem(contributorBidIDs[msg.sender][i]);
        else                                                     // Otherwise no actions are possible.
            revert();
    }

    /* *** Constant and View *** */

    /** @dev Search for the correct insertion spot of a bid.
     *  This function is O(n), where n is the amount of bids between the initial search position and the insertion position.
     *  @param _maxVal The maximum valuation given by the contributor. Or INFINITY if no maximum valuation is given.
     *  @param _nextStart The bidID of next bid in the initial position to start the search.
     *  @return nextInsert The bidID of next bid the bid must be inserted.
     */
    function search(uint _maxVal, uint _nextStart) constant public returns(uint nextInsert) {
        uint next = _nextStart;
        bool found;

        while(!found) { // While we aren't at the insertion point.
            Bid storage nextBid = bids[next];
            uint prev = nextBid.prev;
            Bid storage prevBid = bids[prev];

            if (_maxVal < prevBid.maxVal)       // It should be inserted before.
                next = prev;
            else if (_maxVal >= nextBid.maxVal) // It should be inserted after. The second value we sort by is bidID. Those are increasing, thus if the next bid is of same maxVal, we should insert after.
                next = nextBid.next;
            else                                // We found out the insertion point.
                found = true;
        }

        return next;
    }

    /** @dev Return the current bonus. The bonus only changes in 1/BONUS_DIVISOR increments.
     *  @return b The bonus expressed in 1/BONUS_DIVISOR.
     */
    function bonus() public constant returns(uint b) {
        if (now < endFullBonusTime) // Full bonus.
            return maxBonus;
        else if (now > endTime)     // Assume no bonus after end.
            return 0;
        else                        // Compute the bonus decreasing linearly from endFullBonusTime to endTime.
            return (maxBonus * (endTime - now)) / (endTime - endFullBonusTime);
    }

    /** @dev Get the total contribution of an address.
     *  It can be used for KYC threshold.
     *  The function is O(n) where n is the amount of bids by a the contributor.
     *  This means the contributor can make totalContrib(contributor) reverts due to out of gas on purpose.
     *  @param _contributor The contributor the contribution will be returned.
     *  @return contribution The total contribution of the contributor.
     */
    function totalContrib(address _contributor) public constant returns (uint contribution) {
        for (uint i = 0; i < contributorBidIDs[_contributor].length; ++i)
            contribution += bids[contributorBidIDs[_contributor][i]].contrib;
    }
}
