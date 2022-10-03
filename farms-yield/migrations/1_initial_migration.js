const TTNDEXToken = artifacts.require("TTNDEXToken");
const MasterChef = artifacts.require("MasterChef");
const Provider = require("@truffle/hdwallet-provider");
const Web3 = require("web3");
const provider = new Provider(process.env.MNEMONIC, process.env.BSCTESTNET);
const web3 = new Web3(provider);

module.exports = async function (deployer) {
  await deployer.deploy(TTNDEXToken);

  const block = Number(await web3.eth.getBlockNumber());

  let token = await TTNDEXToken.deployed();

  await deployer.deploy(MasterChef,
    token.address,
    block+10,
    '1000000'
    );

  let masterChef = await MasterChef.deployed();

  await token.transferOwnership(masterChef.address); 
};
