const ExampleBank = artifacts.require("ExampleBank");
const ETHOracle = artifacts.require("ETHOracle");

module.exports = function(deployer, network, accounts) {
  if (network != "rinkeby") {
    return deployer.deploy(ExampleBank, ETHOracle.address, {gas: 4000000});
  }
};
