/* eslint-disable no-undef */ // Avoid the linter considering truffle elements as undef.
const { expectThrow, increaseTime } = require('kleros-interaction/helpers/utils')
const MintableToken = artifacts.require('zeppelin-solidity/MintableToken.sol')
const IICO = artifacts.require('IICO.sol')

// Testing the case presented in the blog
// https://medium.com/kleros/how-interactive-coin-offerings-iicos-work-beed401ce526
// ! ! ! ! ! NOTE THAT WE ARE DOING REFUNDS DIFFERENTLY
// See: https://github.com/kleros/openiico-contract/issues/18
// Bob 6 ETH remains in the sale, up to 20 ETH, remaining 4 ETH gets refunded,

contract('IICO', function (accounts) {
  let owner = accounts[0]
  let beneficiary = accounts[1]
  let buyerA = accounts[2]
  let buyerB = accounts[3]
  let buyerC = accounts[4]
  let buyerD = accounts[5]
  let buyerE = accounts[6]
  let buyerF = accounts[7]
  let gasPrice = 5E9

  let timeBeforeStart = 1000
  let fullBonusLength = 5000
  let partialWithdrawalLength = 2500
  let withdrawalLockUpLength = 2500
  let maxBonus = 2E8
  testAccount = buyerE
  let infinity = 120000000E18; // 120m ETH as a "infinite" cap
  
  it('Test case from the blog', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let iico = await IICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,{from: owner})
    let head = await iico.bids(0)
    let tailID = head[1]
    let tail = await iico.bids(head[1])
    let token = await MintableToken.new({from: owner})
    await token.mint(iico.address,100E18,{from: owner}) // We will use a 100 PNK sale for the example.
    await iico.setToken(token.address,{from: owner})

    increaseTime(1000) // Full bonus period.
    /* ALICE */ await iico.searchAndBid(infinity, 0,{from: buyerA, value:6E18}) // Alice's bid 
    var aliceBid = await iico.bids.call(1);

    increaseTime(5250) // 250 elapsed, 1/20 of 2500+2500
    /* BOB */ await iico.searchAndBid(20E18, 0,{from: buyerB, value:10E18}) // Bob's bid, bonus 19%
    
    increaseTime(250) // another 250 elapsed, 2/20 of 2500
    /* CARL */ await iico.searchAndBid(25E18, 0,{from: buyerC, value:5E18}) // Carl's bid, bonus 18%

    // He will only be able to withdraw whatever percentage is left of the first phase. 
    // Carl withdraws manually 80% of the way through the end of the first phase. 
    increaseTime(1500); // now it's 2000 of 2500 partialWithdrawalLength, which equal to 80%, therefore returning 20% of the bid

    let CarlBalanceBeforeReimbursment = web3.eth.getBalance(buyerC)
    var CarlsBidBefore = await iico.bids.call(3);
    var CarlsBidBeforeBonus = CarlsBidBefore[4].toNumber(); // it's a struct, getting 4 field
    assert.closeTo(CarlsBidBeforeBonus, 1.8E8, 0.01E8, 'Bonus amount not correct before withdrawing the bid');

    await expectThrow(iico.withdraw(3,{from: buyerB})) // Only the contributor can withdraw.
    let tx = await iico.withdraw(3,{from: buyerC, gasPrice: gasPrice})

    await expectThrow(iico.withdraw(3,{from: buyerC, gasPrice: gasPrice})) // cannot withdraw more than once
    let txFee = tx.receipt.gasUsed * gasPrice
    let CarlBalanceAfterReimbursment = web3.eth.getBalance(buyerC)
    assert.closeTo(CarlBalanceBeforeReimbursment.plus(1E18).minus(txFee).toNumber(), CarlBalanceAfterReimbursment.toNumber(), 0.005*1E18, 'Reimbursement amount not correct');

    var CarlsBidAfter = await iico.bids.call(3);
    var CarlsBidAfterBonus = CarlsBidAfter[4].toNumber();
    assert.closeTo(CarlsBidAfterBonus, 1.2E8, 0.01E8, 'Bonus amount not correct, after withdrawal of the bid (reduced by 1/3)');

    // Now David, after seeing how the sale is evolving, decides that he also wants some tokens 
    // and contributes 4 ETH with a personal cap of 24 ETH. He gets an 8% bonus. 
    increaseTime(1000) // now it is 3000 out of 5000
    /* DAVID */ await iico.searchAndBid(24E18, 0, {from: buyerD, value:4E18}) // Davids's bid, bonus 8%

    var DavidsBid = await iico.bids.call(4);
    var DavidsBidBonus = DavidsBid[4].toNumber();
    assert.closeTo(DavidsBidBonus, 0.8E8, 0.01E8, 'Bonus amount not correct');

    increaseTime(1E4) // End of sale.
    
    let buyerABalanceAtTheEndOfSale = web3.eth.getBalance(buyerA).toNumber()
    let buyerBBalanceAtTheEndOfSale = web3.eth.getBalance(buyerB).toNumber()
    let buyerCBalanceAtTheEndOfSale = web3.eth.getBalance(buyerC).toNumber()
    let buyerDBalanceAtTheEndOfSale = web3.eth.getBalance(buyerD).toNumber()
    let beneficiaryBalanceAtTheEndOfSale = web3.eth.getBalance(beneficiary).toNumber()
    
    await iico.finalize(1000)
    
    // Redeem and verify we can't redeem more than once.
    await iico.redeem(1)
    await expectThrow(iico.redeem(1))
    await iico.redeem(2)
    await expectThrow(iico.redeem(2))
    await iico.redeem(3)
    await expectThrow(iico.redeem(3))
    await iico.redeem(4)
    await expectThrow(iico.redeem(4))

    
    // Verify the proper amounts of ETH are refunded.
    assert.equal(web3.eth.getBalance(buyerA).toNumber(), buyerABalanceAtTheEndOfSale, 'The buyer A has been given ETH back while the full bid should have been accepted')
    assert.closeTo(web3.eth.getBalance(buyerB).toNumber(), buyerBBalanceAtTheEndOfSale + 4E18, 0.01*1E18, 'The buyer B has been given ETH back while the full bid should have been accepted')
    assert.equal(web3.eth.getBalance(buyerC).toNumber(), buyerCBalanceAtTheEndOfSale, 'The buyer C has been given ETH back while the full bid should have been accepted')
    assert.equal(web3.eth.getBalance(buyerD).toNumber(), buyerDBalanceAtTheEndOfSale, 'The buyer D has been given ETH back while the full bid should have been accepted')
    
    assert.equal(web3.eth.getBalance(beneficiary).toNumber(), beneficiaryBalanceAtTheEndOfSale+20E18, 'The beneficiary has not been paid correctly')
    
    // Alice: 6 ETH 20% bonus = 7.20
    // Bob:   6 ETH 18% bonus = 7.08
    // Carl:  4 ETH 12% bonus = 4.48
    // David: 4 ETH 8%  bonus = 4.32
    var totalContributed = 7.2 + 7.08 + 4.48 + 4.32;

    var a = (await token.balanceOf(buyerA)).toNumber()
    var b = (await token.balanceOf(buyerB)).toNumber()
    var c = (await token.balanceOf(buyerC)).toNumber()
    var d = (await token.balanceOf(buyerD)).toNumber()

    // Verify that the tokens are correctly distributed.
    assert.closeTo( (await token.balanceOf(buyerA)).toNumber() / 1E18, 7.20 / totalContributed * 100, 1, 'The buyer A has not been given the right amount of tokens')
    assert.closeTo( (await token.balanceOf(buyerB)).toNumber() / 1E18, 7.08 / totalContributed * 100, 1, 'The buyer B has not been given the right amount of tokens')
    assert.closeTo( (await token.balanceOf(buyerC)).toNumber() / 1E18, 4.48 / totalContributed * 100, 1, 'The buyer C has not been given the right amount of tokens')
    assert.closeTo( (await token.balanceOf(buyerD)).toNumber() / 1E18, 4.32 / totalContributed * 100, 1, 'The buyer D has not been given the right amount of tokens')
  
  })
})
