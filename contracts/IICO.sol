/** @title Interactive Coin Offering
 *  @author Clément Lesaege - <clement@lesaege.com>
 */

pragma solidity ^0.4.15;

import "zeppelin-solidity/contracts/token/ERC20/ERC20.sol";

/** @title Interactive Coin Offering
 *  This contract implements the Interactive Coin Offering token sale as described in this paper:
 *  https://people.cs.uchicago.edu/~teutsch/papers/ico.pdf
 *  Modifications compared to the paper:
 *  -A fix amount of tokens is sold. This allows more flexibility for the distribution of the remaining tokens (round, team tokens which can be preallocated, non-initial sell of some cryptographic assets).
 *  -The pointer is only moved when the sale is over. This greatly reduces the amount of write operations and code complexity. However at least one party must make one or multiple calls to finalized
 *  -Buckets are not used as they are not required and increases code complexity.
 *  -The bid submitter must provide the insertion spot. A search of the insertion spot is still done in the contract, but giving the search starting point greatly lower gas. The search is required as the correct insertion spot can change before a TX is signed and its execution.
 *  -Automatic withdrawals are only possible at the end of the sale. This decreases code complexity and interactions.
 *  -We put a full bonus, free withdrawal period at the beginning. This allows everyone to have a chance to place bids with full bonus and avoid clogging the network just after the sale starts. Note that at this moment, no information can be taken from granted as parties can withdraw freely.
 */
contract IICO {
    
    /* *** General *** */
    address owner;       // The one setting up the contract.
    address beneficiary; // The address which will get the funds.
    
    /* *** Bid *** */
    uint constant HEAD = 0;            // Minimum value used for both the maxVal and bidID of the head of the linked list.
    uint constant TAIL = uint(-1);     // Maximum value used for both the maxVal and bidID of the tail of the linked list.
    uint constant INFINITY = uint(-2); // A value so high that a bid using it is guarantee to suceed. Still lower than TAIL to be placed before TAIL.
    // A bid to buy tokens as long as the personal max valuation is not exceeded.
    // Bids are in a sorted doubly linked list.
    // They are sorted in ascending order by (maxVal,bidID) where bidID is the ID and index of the bid in the mapping.
    // The list contains two artificial bids HEAD and TAIL having respectively the minimum and maximum bidID and maxVal.
    struct Bid {
        /* *** Linked List Members *** */
        uint prev;            // bidID of the previous element.
        uint next;            // bidID of the next element.
        /* ***     Bid Members     *** */
        uint maxVal;          // Maximum valuation given by the bidder.
        uint contrib;         // Contribution in wei of the bidder.
        uint virtualContrib;  // Virtual contribution (taking into account bonuses) of the bidder.
        address contributor;  // The contributor which placed the bid.
        bool withdrawn;       // True if the bid has been withdrawn.
        bool redeemed;        // True if the ETH or tokens has been redeemed.
    }
    mapping (uint => Bid) public bids; // Map bidID to Bid.
    mapping (address => uint[]) public contributorBidIDs; // Map contributor to a list of its bid ID.
    uint public lastBidID=0; // The last bidID not accounting TAIL.
    
    /* *** Sale parameters *** */
    uint public startTime;                      // When the sale starts.
    uint public endFullBonusTime;               // When the full bonus ends.
    uint public withdrawalLockTime;             // When the contributors can't withdraw their bids anymore.
    uint public endTime;                        // When the sale ends.
    ERC20 public token;                         // The token which is sold.
    uint public tokensForSale;                  // The amount of tokens which will be sold.
    uint public maxBonusPermil;                 // The maximum bonus in ‰.
    uint constant PER_MIL_DIVISOR=uint(1000);   // The quantity we need to divide by to normalize ‰.
    
    /* *** Finalization variables *** */
    bool public finalized;                 // True when the cutting bid has been found.
    uint public cutOffBidID=TAIL;          // The last accepted bid. All bids next it are accepted. Final only if finalized==true.
    uint public sumAcceptedContrib;        // The sum of accepted contributions. Final only if finalized==true. 
    uint public sumAcceptedVirtualContrib; // The sum of virtual (taking into account bonuses) contributions. Final only if finalized==true.
    
    modifier onlyOwner{ require(owner==msg.sender); _; }
    
    /* *** Functions Modifying the state *** */
    
    /** @dev Constructor. First contract set up (tokens will also need to be transfered to the contract and then setToken to be called to finish the setup).
     *  @param _startTime Time the sale will start in Unix Timestamp.
     *  @param _fullBonusLength Amount of seconds the sale lasts in the full bonus period.
     *  @param _partialWithdrawalLength Amount of seconds the sale lasts in the partial withdrawal period.
     *  @param _withdrawalLockUpLenght Amount of seconds the sale lasts in the withdrawal lockup period.
     *  @param _maxBonusPermil The maximum bonus in ‰.
     */
    function IICO(uint _startTime, uint _fullBonusLength, uint _partialWithdrawalLength, uint _withdrawalLockUpLenght, ERC20 _token, uint _maxBonusPermil) public {
        owner=msg.sender;
        startTime=_startTime;
        endFullBonusTime=startTime+_fullBonusLength;
        withdrawalLockTime=endFullBonusTime+_partialWithdrawalLength;
        endTime=withdrawalLockTime+_withdrawalLockUpLenght;
        token=_token;
        maxBonusPermil=_maxBonusPermil;
        
        // Add the virtual bids. This simplifies other functions.
        bids[HEAD]=Bid({
            prev: TAIL,
            next: TAIL,
            maxVal: HEAD,
            contrib: 0,
            virtualContrib: 0,
            contributor: 0x0,
            withdrawn: false,
            redeemed: false
        });
        bids[TAIL]=Bid({
            prev: HEAD,
            next: HEAD,
            maxVal: TAIL,
            contrib: 0,
            virtualContrib: 0,
            contributor: 0x0,
            withdrawn: false,
            redeemed: false
        });
    }
    
    /** @dev Set the token. Must only be called after the IICO contract receive the tokens to be sold.
     *  @param _token The token to be sold.
     */    
    function setToken(ERC20 _token) public onlyOwner {
        require(address(token)==0x0);
        
        token=_token;
        tokensForSale=token.balanceOf(this);
    }
    
    /** @dev Submit a bid. The caller must give the exact position the bid must be inserted in the list.
     *  In practice use searchAndBid to avoid the position being incorrect due a new bid being inserted changing the position the bid must be inserted.
     *  @param _maxVal The maximum valuation given by the contributor. If the amount raised is higher, the bid is cancelled and the contributor refunded because it prefers refund instead of this level of dilution. 
     *  @param _next The bidID of next bid to the bid which will inserted.
     */
    function submitBid(uint _maxVal, uint _next) public payable {
        ++lastBidID; // Increment the lastBidID. It will be the one of the bid which will be inserted.
        Bid storage nextBid = bids[_next];
        uint prev   = nextBid.prev;
        Bid storage prevBid = bids[prev];
        require(_maxVal>=prevBid.maxVal && _maxVal<nextBid.maxVal); // The new bid maxVal is higher than the previous and strictly lower than the next.
        require(now>=startTime && now<=endTime); // Check the bids are open.
        
        // Update the pointers of neighboring bids.
        prevBid.next=lastBidID;
        nextBid.prev=lastBidID;
        
        // Insert the bid.
        bids[lastBidID]=Bid({
            prev: prev,
            next: _next,
            maxVal: _maxVal,
            contrib: msg.value,
            virtualContrib: (msg.value*bonus())/PER_MIL_DIVISOR,
            contributor: msg.sender,
            withdrawn: false,
            redeemed: false
        });
        
        // Update the list of bids by this contributor.
        contributorBidIDs[msg.sender].push(lastBidID);
    }
    
    
    /** @dev Search the correct insertion spot and submit a bid.
     *  This function is O(n), where n is the amount of bids between the initial search position and the insertion position.
     *  The UI must first call search to find the best point to start the search and consume the least amount of gas.
     *  Using this function instead of calling submitBid directly prevents it to fail in the case that new bids would be added before the transaction is executed.
     *  @param _maxVal The maximum valuation given by the contributor. If the amount raised is higher, the bid is cancelled and the contributor refunded because it prefers refund instead of this level of dilution. 
     *  @param _next The bidID of next bid to the bid which will inserted.
     */
    function searchAndBid(uint _maxVal, uint _next) public payable {
        submitBid(_maxVal,search(_maxVal,_next));
    }
    
    /** @dev Withdraw a bid. Can only be called before the end of the withdrawal lock.
     *  For the automatic withdrawal explained in the paper, use the redeem function.
     *  @param _bidID ID of the bid to withdraw.
     */
    function withdraw(uint _bidID) public {
        Bid storage bid = bids[_bidID];
        require(msg.sender==bid.contributor);
        require(now<withdrawalLockTime);
        require(!bid.withdrawn);
        
        bid.withdrawn=true;
        
        // Compute which ‰ will be refunded. All of it if before endFullBonusTime. Otherwise an amount decreasing linearly from endFullBonusTime to withdrawalLockTime.
        uint refundPerMil = (now<endFullBonusTime) ? PER_MIL_DIVISOR : (PER_MIL_DIVISOR*(withdrawalLockTime-now))/(withdrawalLockTime-endFullBonusTime);
        uint refund = (bid.contrib*refundPerMil)/PER_MIL_DIVISOR;
        assert(refund<=bid.contrib); // Make sure that we don't refund more than the contribution. Would a bug arise, we prefer blocking withdrawal than letting someone steal money.
        bid.virtualContrib -= refund + (bid.virtualContrib-bid.contrib)/3;
        bid.contrib -= refund;
        
        msg.sender.transfer(refund);
    }
    
    /** @dev Finalize by finding the cut-off bid.
     *  Since the amount of bids is not bounded, this function may have to be called multiple times.
     *  The function is in O(max(n,maxIt)) where n is the amount of bids. In total it will perform O(n) computations, possibly in multiple calls.
     *  Each call only has a O(1) storage updates.
     *  @param _maxIt The maximum amount of bids to go through. This value must be set in order to not exceed the gas limit.
     */
    function finalize(uint _maxIt) public {
        require(now>endTime);
        require(!finalized);
        
        // Make local copies of the finalization varaibles in order to avoid modifying storage in order to save gas.
        uint localCutOffBidID=cutOffBidID;
        uint localSumAcceptedContrib=sumAcceptedContrib;
        uint localSumAcceptedVirtualContrib=sumAcceptedVirtualContrib;
        
        // Search for the cut-off while counting the contributions.
        // Note that this 
        for (uint it;it<_maxIt&&!finalized;++it) {
            Bid storage bid = bids[localCutOffBidID];
            if (bid.contrib+localSumAcceptedContrib<bid.maxVal) { // We haven't found the cut-off yet.
                localSumAcceptedContrib        += bid.contrib;
                localSumAcceptedVirtualContrib += bid.virtualContrib;
                localCutOffBidID = bid.prev; // Go to previous bid.
            }else { // We found the cut-off. This bid will be taken partially.
                finalized=true;
                uint contribCutOff = bid.maxVal - localSumAcceptedContrib; // The contribution of the cut-off bid.
                bid.contributor.send(bid.contrib-contribCutOff);     // Send the non-accepted part. Use of send in order not to block in case the contributor fallback would revert.
                bid.virtualContrib = (contribCutOff * bid.virtualContrib) / bid.contrib; // Remove a fraction of the virtual contribution equal to the non accepted contribution one.
                bid.contrib = contribCutOff; // Update the contribution value.
                localSumAcceptedContrib += bid.contrib;
                localSumAcceptedVirtualContrib += bid.virtualContrib;
                beneficiary.send(localSumAcceptedContrib); // Use of send in order not to allow the beneficiary to block the fubalization.
            }
        }
        
        // Update storage.
        cutOffBidID=localCutOffBidID;
        sumAcceptedContrib=localSumAcceptedContrib;
        sumAcceptedVirtualContrib=localSumAcceptedVirtualContrib;
    }
    
    /** @dev Redeem a bid. If the bid is accepted, send get the tokens, otherwise get the ethers back.
     *  Note that anyone can call this function, not only the party which made the bid.
     *  @param _bidID ID of the bid to withdraw.
     */
    function redeem(uint _bidID) public {
        Bid storage bid = bids[_bidID];
        Bid storage cutOffBid = bids[cutOffBidID];
        require(finalized);
        require(!bid.redeemed);
        
        bid.redeemed=true;
        if (bid.maxVal>cutOffBid.maxVal || (bid.maxVal==cutOffBid.maxVal && _bidID>=cutOffBidID)) // Give tokens if the bid is accepted.
            token.transfer(bid.contributor,(bid.virtualContrib*tokensForSale)/sumAcceptedVirtualContrib);
        else                                                                                      // Reimburse otherwise.
            bid.contributor.transfer(bid.contrib);
    }
    
    /** @dev Fallback. Make a bid if sale is not over. Redeem it if it is.
     *  This allows unsophisticated users to bid and get their tokens back by only doing send to the contract.
     */
    function () public payable {
        if (msg.value!=0 && now>=startTime && now<=endTime)  // Make some bid with an infinite maxVal if some ETH were sent.
            submitBid(INFINITY,TAIL);
        else if (msg.value==0 && finalized)                  // Redeem all the non-already redeemed bids if no eth were sent.
            for (uint i=0;i<contributorBidIDs[msg.sender].length;++i)
                if (!bids[contributorBidIDs[msg.sender][i]].redeemed)
                    redeem(contributorBidIDs[msg.sender][i]);
        else                                                 // Otherwise no actions is possible and revert.
            revert();
    }
    
    /* *** Constant and View *** */
    
    /** @dev Search for the correct insertion spot for a bid.
     *  This function is O(n), where n is the amount of bids between the initial search position and the insertion position.
     *  @param _maxVal The maximum valuation given by the contributor.
     *  @param _nextStart The bidID of next bid in the initial position to start the search.
     *  @return nextInsert The bidID of next bid to the bid which will inserted.
     */
    function search(uint _maxVal, uint _nextStart) constant public returns(uint nextInsert) {
        uint next=_nextStart;
        bool found;


        while(!found) { // While we aren't at the insertion point.
            Bid storage nextBid = bids[next];
            uint prev   = nextBid.prev;
            Bid storage prevBid = bids[prev];
            
            if (_maxVal<prevBid.maxVal)       // It should be inserted before.
                next=prev;
            else if (_maxVal>=nextBid.maxVal) // It should be inserted after. The second value we sort by are bidID. Those are increasing, thus if the next bid is of same maxVal, we should insert after.
                next=nextBid.next;
            else                              // We found out the insertion point.
                found = true;
        }
        
        return next;
    }
    
    /** @dev Return the current bonus. The bonus only change in 1‰ increments.
     *  @return b The bonus in ‰.
     */
    function bonus() public constant returns(uint b) {
        if (now<endFullBonusTime)  // Full bonus.
            return maxBonusPermil;
        else if (now>endTime)      // Assume no bonus after end.
            return 0;
        else                       // Compute the bonus decreasing linearly from endFullBonusTime to endTime.
            return (maxBonusPermil*(endTime-now))/(endTime-endFullBonusTime);
    }
    
    /** @dev Get the total contribution of an address.
     *  It can be used for KYC threshold.
     *  The function is O(n) where n is the amount of bids by a the contributor.
     *  This means the contributor can make contribution(contributor) reverts due to out of gas on purpose.
     */
    function totalContrib(address _contributor) public constant returns (uint contribution) {
        for (uint i=0;i<contributorBidIDs[_contributor].length;++i)
            contribution+=bids[contributorBidIDs[_contributor][i]].contrib;
    }
}



