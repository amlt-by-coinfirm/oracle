// This is for hitting and testing all the require()s we use
const truffleAssert = require('truffle-assertions');

const ETHOracleContract = artifacts.require("ETHOracle");

contract("ETHOracle", async accounts => {
  beforeEach('setup', async () => {
    ETHOracle = await ETHOracleContract.deployed();
  });


  context("Hitting the rest of our require()s", () => {

    it("Try to get AML Status query fee", async () => {
      await truffleAssert.reverts(
        ETHOracle.getAMLStatusFee("0x0000000000000000000000000000000000000000", "bogusaddress"),
        "BaseAMLOracle: client must not be 0x0"
      );
    });

    it("Try to get AML Status query timestamp", async () => {
      await truffleAssert.reverts(
        ETHOracle.getAMLStatusTimestamp("0x0000000000000000000000000000000000000000", "bogusaddress"),
        "BaseAMLOracle: client must not be 0x0"
      );
    });

    it("Try to get non-existent AML Status Metadata", async () => {
      await truffleAssert.reverts(
        ETHOracle.getAMLStatusMetadata("bogusaddress"),
        "BaseAMLOracle: no such AML status"
      );
    });

    it("Try to get AML Status Metadata as 0x0", async () => {
      await truffleAssert.reverts(
        ETHOracle.methods["getAMLStatusMetadata(address,string)"]("0x0000000000000000000000000000000000000000", "bogusaddress"),
        "BaseAMLOracle: client must not be 0x0"
      );
    });

    it("Trying to fetch AML status for 'bogusaddress'", async () => {
      await truffleAssert.reverts(
        ETHOracle.fetchAMLStatus(100, "bogusaddress"),
        "BaseAMLOracle: no such AML status"
      );
    });

    it("Trying to fetch AML status for ''", async () => {
      await truffleAssert.reverts(
        ETHOracle.fetchAMLStatus(100, ""),
        "BaseAMLOracle: target must not be an empty string"
      );
    });

    it("Testing maxFee on fetch", async () => {
      await ETHOracle.setAMLStatus(accounts[0], "realaddress", web3.utils.fromAscii("123456789"), 99, 0x1, 123),
      await truffleAssert.reverts(
        ETHOracle.fetchAMLStatus(100, "realaddress"),
        "BaseAMLOracle: the required fee is greater than the specified maximum fee"
      );
    });

    it("Trying to fetch without balance fetch", async () => {
      await ETHOracle.setAMLStatus(accounts[0], "realaddress", web3.utils.fromAscii("123456789"), 99, 0x1, 123),
      await truffleAssert.reverts(
        ETHOracle.fetchAMLStatus(123, "realaddress"),
        "SafeMath: subtraction overflow"
      );
    });

    it("Ask AML Status for ''", async () => {
      await truffleAssert.reverts(
        ETHOracle.askAMLStatus(0, ""),
        "BaseAMLOracle: target must not be an empty string"
      );
    });

    it("Delete AML Status for ''", async () => {
      await truffleAssert.reverts(
        ETHOracle.deleteAMLStatus(accounts[0], ""),
        "BaseAMLOracle: target must not be an empty string"
      );
    });

    it("Delete AML Status for 0x0", async () => {
      await truffleAssert.reverts(
        ETHOracle.deleteAMLStatus("0x0000000000000000000000000000000000000000", "bogusaddress"),
        "BaseAMLOracle: cannot delete AML status for 0x0"
      );
    });

    it("Set AML Status for 0x0", async () => {
      await truffleAssert.reverts(
        ETHOracle.setAMLStatus("0x0000000000000000000000000000000000000000", "bogusaddress", web3.utils.fromAscii("123456789"), 99, 0x1, 123),
        "BaseAMLOracle: cannot set AML status for 0x0"
      );
    });

    it("Set AML status for ''", async () => {
      await truffleAssert.reverts(
        ETHOracle.setAMLStatus(accounts[0], "", web3.utils.fromAscii("123456789"), 99, 0x1, 123),
        "BaseAMLOracle: target must not be an empty string"
      );
    });

    it("Use cScore above 99", async () => {
      await truffleAssert.reverts(
        ETHOracle.setAMLStatus(accounts[0], "bogusaddress", web3.utils.fromAscii("123456789"), 123, 0x1, 123),
        "BaseAMLOracle: the cScore must be between 0 and 99"
      );
    });

    it("Notify 0x0", async () => {
      await truffleAssert.reverts(
        ETHOracle.notify("0x0000000000000000000000000000000000000000", "bogusmessage"),
        "BaseAMLOracle: client must not be 0x0"
      );
    });

    it("Set fee account to 0x0", async () => {
      await truffleAssert.reverts(
        ETHOracle.setFeeAccount("0x0000000000000000000000000000000000000000"),
        "BaseAMLOracle: the fee account must not be 0x0"
      );
    });

    it("Trying to withdraw more than user's balance is", async () => {
      await truffleAssert.reverts(
        ETHOracle.withdrawETH(1),
        "SafeMath: subtraction overflow"
      );
    });

    it("Withdraw 0 amount", async () => {
      await truffleAssert.reverts(
        ETHOracle.withdrawETH(0),
        "BaseAMLOracle: amount to withdraw must be greater than 0"
      );
    });

    it("Trying to donate for a client not accepting donations", async () => {
      await truffleAssert.reverts(
        ETHOracle.donateETH(accounts[0], {from: accounts[0], value: 1}),
        "BaseAMLOracle: the account does not accept donations"
      );
    });

    it("Deposit 0 amount", async () => {
      await truffleAssert.reverts(
        ETHOracle.sendTransaction({from: accounts[0], value: 0}),
        "BaseAMLOracle: amount to deposit must be greater than 0"
      );
    });
  });


  context('Trying to access privileged functions as a non-privileged user', () => {
    it("setDefaultFee()", async () => {
      await truffleAssert.reverts(
        ETHOracle.setDefaultFee(0, {from:accounts[1]}),
        "BaseAMLOracle: the caller is not allowed to set the default fee"
      );
    });

    it("setFeeAccount()", async () => {
      await truffleAssert.reverts(
        ETHOracle.setFeeAccount("0x0000000000000000000000000000000000000000", {from:accounts[1]}),
        "BaseAMLOracle: the caller is not allowed to set the fee account"
      );
    });

    it("notify()", async () => {
      await truffleAssert.reverts(
        ETHOracle.notify(accounts[0], "bogus message", {from:accounts[1]}),
        "BaseAMLOracle: the caller is not allowed to notify the clients"
      );
    });

    it("setAMLStatus()", async () => {
      await truffleAssert.reverts(
        ETHOracle.setAMLStatus(accounts[0], "bogusaddress", web3.utils.fromAscii("123456789"), 11, 0x1, 123, {from:accounts[1]}),
        "BaseAMLOracle: the caller is not allowed to set AML statuses"
      );
    });

    it("deleteAMLStatus()", async () => {
      await truffleAssert.reverts(
        ETHOracle.deleteAMLStatus(accounts[0], "bogusaddress", {from:accounts[1]}),
        "BaseAMLOracle: the caller is not allowed to delete AML statuses"
      );
    });

    it("recoverTokens()", async () => {
      await truffleAssert.reverts(
        ETHOracle.recoverTokens(accounts[0], {from:accounts[1]}),
        "RecoverTokens: the caller is not allowed to recover tokens"
      );
    });
  });
});
