 /* eslint-disable no-undef */ // Avoid the linter considering truffle elements as undef.
const { expectThrow, increaseTime } = require('kleros-interaction/helpers/utils')
const MintableToken = artifacts.require('zeppelin-solidity/MintableToken.sol')
const IICO = artifacts.require('IICO.sol')


contract('IICO', function (accounts) {
  let owner = accounts[0]
  let beneficiary = accounts[1]
  let buyerA = accounts[2]
  let buyerB = accounts[3]
  let buyerC = accounts[4]
  let buyerD = accounts[5]
  let buyerE = accounts[6]
  let gasPrice = 5000000000

  
  let timeBeforeStart = 1000
  let fullBonusLength = 5000
  let partialWithdrawalLength = 2500
  let withdrawalLockUpLength = 2500
  let maxBonus = 2E8
  testAccount = buyerE
  
  

  // Constructor
  it('Should create the contract with the initial values', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let iico = await IICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,{from: owner})
    let head = await iico.bids(0)
    let tailID = head[1]
    let tail = await iico.bids(tailID)
    
    
    assert.equal(await iico.owner(), owner, 'The owner is not set correctly')
    assert.equal(await iico.beneficiary(), beneficiary, 'The beneficiary is not set correctly')
    assert.equal(await iico.lastBidID(), 0, 'The lastBidID is not set correctly')
    assert.equal(await iico.startTime(), startTestTime+1000, 'The startTime is not set correctly')
    assert.equal(await iico.endFullBonusTime(), startTestTime+6000, 'The endFullBonusTime is not set correctly')
    assert.equal(await iico.withdrawalLockTime(), startTestTime+8500, 'The endFullBonusTime is not set correctly')
    assert.equal(await iico.endTime(), startTestTime+11000, 'The endFullBonusTime is not set correctly')
    assert.equal(await iico.maxBonus(), 2E8, 'The maxBonus is not set correctly')
    assert.equal(await iico.finalized(), false, 'The finalized is not set correctly')
    assert.equal((await iico.cutOffBidID()).toNumber(), head[1].toNumber(), 'The cutOffBidID is not set correctly')
    assert.equal(await iico.sumAcceptedContrib(), 0, 'The sumAcceptedContrib is not set correctly')
    assert.equal(await iico.sumAcceptedVirtualContrib(), 0, 'The sumAcceptedVirtualContrib is not set correctly')
  })

  // setToken
  it('Should set the token', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let iico = await IICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,{from: owner})
    let token = await MintableToken.new({from: owner})
    await token.mint(iico.address,160E24,{from: owner})
    await expectThrow(iico.setToken(token.address,{from: buyerA})) // Only owner can set.
    await iico.setToken(token.address,{from: owner})

    assert.equal(await iico.token(), token.address, 'The token is not set correctly')
    assert.equal(await iico.tokensForSale(), 160E24, 'The tokensForSale is not set correctly')
  })

  // submitBid
  it('Should submit only valid bids', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let iico = await IICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,{from: owner})
    let head = await iico.bids(0)
    let tailID = head[1]
    let tail = await iico.bids(tailID)
    let token = await MintableToken.new({from: owner})
    await token.mint(iico.address,160E24,{from: owner})
    await iico.setToken(token.address,{from: owner})

    await expectThrow(iico.submitBid(1E18, head[1],{from: buyerA, value:0.1E18})) // Should not work before the sale hasn't start yet.
    increaseTime(1010) // Full bonus period.
    await iico.submitBid(1E18, head[1],{from: buyerA, value:0.1E18}) // Bid 1.
    await expectThrow(iico.submitBid(0.5E18, head[1],{from: buyerB, value:0.1E18})) // Should not work because not inserted in the right position.
    await expectThrow(iico.submitBid(0.5E18, 0,{from: buyerB, value:0.1E18}))
    await iico.submitBid(0.5E18, 1,{from: buyerB, value:0.1E18}) // Bid 2.
    
    increaseTime(5000) // Partial bonus period.
    await iico.submitBid(0.8E18, 1,{from: buyerC, value:0.15E18}) // Bid 3.
    increaseTime(2500) // Withdrawal lock period.
    await iico.submitBid(0.7E18, 3,{from: buyerD, value:0.15E18}) // Bid 4.
    increaseTime(2500) // End of sale period.
    await expectThrow(iico.submitBid(0.9E18, 1,{from: buyerE, value:0.15E18}))
  })
  
  
  
  // searchAndBid
  it('Should submit even if not the right position', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let iico = await IICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,{from: owner})
    let head = await iico.bids(0)
    let tailID = head[1]
    let tail = await iico.bids(tailID)
    let token = await MintableToken.new({from: owner})
    await token.mint(iico.address,160E24,{from: owner})
    await iico.setToken(token.address,{from: owner})

    increaseTime(1010) // Full bonus period.
    await iico.searchAndBid(1E18, 0,{from: buyerA, value:0.1E18}) // Bid 1.
    await iico.searchAndBid(0.5E18, 1,{from: buyerB, value:0.1E18}) // Bid 2.
    increaseTime(5000) // Partial bonus period.
    await iico.searchAndBid(0.8E18, 2,{from: buyerC, value:0.15E18}) // Bid 3.
    increaseTime(2500) // Withdrawal lock period.
    await iico.searchAndBid(0.7E18, 0,{from: buyerD, value:0.15E18}) // Bid 4.
    await iico.searchAndBid(0.5E18, tailID,{from: buyerE, value:0.1E18}) // Bid 5.
  })  
  
  // withdraw
  it('Should withdraw the proper amount', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let iico = await IICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,{from: owner})
    let head = await iico.bids(0)
    let tailID = head[1]
    let tail = await iico.bids(head[1])
    let token = await MintableToken.new({from: owner})
    await token.mint(iico.address,160E24,{from: owner})
    await iico.setToken(token.address,{from: owner})

    increaseTime(1010) // Full bonus period.
    await iico.searchAndBid(1E18, 0,{from: buyerA, value:0.1E18}) // Bid 1.
    let buyerABalanceBeforeReimbursment = web3.eth.getBalance(buyerA)
    await expectThrow(iico.withdraw(1,{from: buyerB})) // Only the contributor can withdraw.
    let tx = await iico.withdraw(1,{from: buyerA, gasPrice: gasPrice})
    let txFee = tx.receipt.gasUsed * gasPrice
    let buyerABalanceAfterReimbursment = web3.eth.getBalance(buyerA)
    assert.equal(buyerABalanceBeforeReimbursment.plus(0.1E18).minus(txFee).toNumber(), buyerABalanceAfterReimbursment.toNumber(), 'The buyer has not been reimbursed completely')
    await expectThrow(iico.withdraw(1,{from: buyerA, gasPrice: gasPrice}))
    
    await iico.searchAndBid(0.8E18, 2,{from: buyerB, value:0.1E18}) // Bid 2.
    increaseTime(5490) // Partial bonus period. Around 20% locked.
    let buyerBBalanceBeforeReimbursment = web3.eth.getBalance(buyerB)
    tx = await iico.withdraw(2,{from: buyerB, gasPrice: gasPrice})
    txFee = tx.receipt.gasUsed * gasPrice
    let buyerBBalanceAfterReimbursment = web3.eth.getBalance(buyerB)
    assert(buyerBBalanceAfterReimbursment.minus(buyerBBalanceBeforeReimbursment.minus(txFee).toNumber()).toNumber()-4*0.1E18/5 <= (4*0.1E18/5)/100, 'The buyer has not been reimbursed correctly') // Allow up to 1% error due to time taken outside of increaseTime.
    await expectThrow(iico.withdraw(2,{from: buyerB, gasPrice: gasPrice})) // You should not be able to withdraw twice.
    
    await iico.searchAndBid(0.5E18, 2,{from: buyerC, value:0.15E18}) // Bid 3.
    increaseTime(2500)
    await expectThrow(iico.withdraw(3,{from: buyerC})) // Not possible to withdraw after the withdrawal lock.
  })
  
  // finalized
  it('Should finalize in one shot', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let iico = await IICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,{from: owner})
    let head = await iico.bids(0)
    let tailID = head[1]
    let tail = await iico.bids(head[1])
    let token = await MintableToken.new({from: owner})
    await token.mint(iico.address,160E24,{from: owner})
    await iico.setToken(token.address,{from: owner})

    increaseTime(1010) // Full bonus period.
    await iico.searchAndBid(1E18, 0,{from: buyerA, value:0.1E18}) // Bid 1.
    await iico.searchAndBid(0.5E18, 1,{from: buyerB, value:0.1E18}) // Bid 2.
    increaseTime(5000) // Partial bonus period.
    await iico.searchAndBid(0.8E18, 2,{from: buyerC, value:0.15E18}) // Bid 3.
    increaseTime(2500) // Withdrawal lock period.
    await iico.searchAndBid(0.7E18, 0,{from: buyerD, value:0.15E18}) // Bid 4.
    await iico.searchAndBid(0.5E18, tailID,{from: buyerE, value:0.1E18}) // Bid 5.
    await expectThrow(iico.finalize(1000000000000)) // Should not be able to finalize before the end of the sale.
    increaseTime(2500) // Withdrawal lock period.
    await iico.finalize(1000000000000)
    assert.equal(await iico.finalized(), true, 'The one shot finalization did not work as expected')
  })
  
  
  it('Should finalize in multiple shots', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let iico = await IICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,{from: owner})
    let head = await iico.bids(0)
    let tailID = head[1]
    let tail = await iico.bids(head[1])
    let token = await MintableToken.new({from: owner})
    await token.mint(iico.address,160E24,{from: owner})
    await iico.setToken(token.address,{from: owner})
    
    
    increaseTime(1010) // Full bonus period.
    await iico.searchAndBid(1E18, 0,{from: buyerA, value:0.1E18}) // Bid 1.
    await iico.searchAndBid(0.5E18, 1,{from: buyerB, value:0.1E18}) // Bid 2.
    increaseTime(5000) // Partial bonus period.
    await iico.searchAndBid(0.8E18, 2,{from: buyerC, value:0.4E18}) // Bid 3.
    increaseTime(2500) // Withdrawal lock period.
    await iico.searchAndBid(0.7E18, 0,{from: buyerD, value:0.2E18}) // Bid 4.
    await iico.searchAndBid(0.5E18, tailID,{from: buyerE, value:0.1E18}) // Bid 5.
    increaseTime(2500) // Withdrawal lock period.
    await iico.finalize(2)
    assert.equal(await iico.finalized(), false, 'The multiple shots finalization finalized while it should have taken longer')
    await iico.finalize(2)
    assert.equal(await iico.finalized(), true, 'The multiple shots finalization did not work as expected')
  })
  
})





