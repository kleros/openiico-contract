/* eslint-disable no-undef */ // Avoid the linter considering truffle elements as undef.
const { expectThrow, increaseTime } = require('kleros-interaction/helpers/utils')
const MintableToken = artifacts.require('zeppelin-solidity/MintableToken.sol')
const LWIICO = artifacts.require('LevelWhitelistedIICO.sol')

contract('IICO', function (accounts) {
  let owner = accounts[0]
  let beneficiary = accounts[1]
  let buyerA = accounts[2]
  let buyerB = accounts[3]
  let whitelister = accounts[4]
  let whitelister2 = accounts[5]
  let gasPrice = 5E9

  
  let timeBeforeStart = 1000
  let fullBonusLength = 5000
  let partialWithdrawalLength = 2500
  let withdrawalLockUpLength = 2500
  let maxBonus = 2E8
  let noCap = 120000000E18 // for placing bids with no cap
  let maximumBaseContribution = 5E18
  
  // Constructor
  it('Should create the contract with the initial values', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let lwiico = await LWIICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,maximumBaseContribution,{from: owner})
    assert.equal((await lwiico.maximumBaseContribution.call()).toNumber(), maximumBaseContribution, 'Maximum base contribution not set correctly')
    assert.equal(await lwiico.whitelister.call(), 0, 'Whitelister should not be set initially')
  })  

  it('Should be able to set and change whitelister (only owner)', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let lwiico = await LWIICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,maximumBaseContribution,{from: owner})

    await lwiico.setWhitelister(whitelister,{from: owner});
    assert.equal(await lwiico.whitelister.call(), whitelister, 'Whitelister is not set')    

    await lwiico.setWhitelister(whitelister2,{from: owner});
    assert.equal(await lwiico.whitelister.call(), whitelister2, 'Whitelister is not changed')
  })    

  it('Should not be able to set and change whitelister (anyone else)', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let lwiico = await LWIICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,maximumBaseContribution,{from: owner})

    await expectThrow(lwiico.setWhitelister(whitelister,{from: buyerA}));
  })    

  it('Should be forbidden to send ETH without whitelist', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let lwiico = await LWIICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,maximumBaseContribution,{from: owner})

    increaseTime(1010) // time of the crowdasle

    await expectThrow(lwiico.searchAndBid(1E18, 0,{from: buyerA, value:0.1E18}))
  })   

  it('Should be possible to send ETH after whitelisting', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let lwiico = await LWIICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,maximumBaseContribution,{from: owner})

    await lwiico.setWhitelister(whitelister,{from: owner});
    await lwiico.addBaseWhitelist([buyerA],{from: whitelister}) 

    increaseTime(1010) // time of the crowdasle

    lwiico.searchAndBid(1E18, 0, {from: buyerA, value:0.1E18});

    var bid = await lwiico.bids.call(1);
    assert.equal(bid[5], buyerA, "Bid is not properly saved");
  })    

  it('Should not be possible to send too much ETH after whitelisting', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let lwiico = await LWIICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,maximumBaseContribution,{from: owner})

    await lwiico.setWhitelister(whitelister,{from: owner});
    await lwiico.addBaseWhitelist([buyerA],{from: whitelister}) 

    increaseTime(1010) // time of the crowdasle

    await expectThrow(lwiico.searchAndBid(1E18, 0, {from: buyerA, value: maximumBaseContribution+1}));
  }) 

  it('Should not be possible to send too much ETH after whitelisting in multiple goes', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let lwiico = await LWIICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,maximumBaseContribution,{from: owner})

    await lwiico.setWhitelister(whitelister,{from: owner});
    await lwiico.addBaseWhitelist([buyerA],{from: whitelister}) 

    increaseTime(1010) // time of the crowdasle

    lwiico.searchAndBid(1E18, 0, {from: buyerA, value: 1E18});

    increaseTime(100);

    await expectThrow(lwiico.searchAndBid(1E18, 0, {from: buyerA, value: 4.5E18}));
  })    

  it('Should not be possible to send ETH after removing from whitelist', async () => {
    let startTestTime = web3.eth.getBlock('latest').timestamp
    let lwiico = await LWIICO.new(startTestTime+timeBeforeStart,fullBonusLength,partialWithdrawalLength, withdrawalLockUpLength,maxBonus,beneficiary,maximumBaseContribution,{from: owner})

    await lwiico.setWhitelister(whitelister,{from: owner});
    await lwiico.addBaseWhitelist([buyerA],{from: whitelister}) 

    increaseTime(1010) // time of the crowdasle

    lwiico.searchAndBid(1E18, 0, {from: buyerA, value: 1E18});

    increaseTime(100);

    await lwiico.removeBaseWhitelist([buyerA],{from: whitelister}) 

    await expectThrow(lwiico.searchAndBid(1E18, 0, {from: buyerA, value: 1E18}));
  })    





});