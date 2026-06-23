const { ethers } = require("ethers");

// Your hex private key (ensure it starts with '0x')
const privateKey = process.env.PRIVATE_KEY;

// Create a wallet instance
const wallet = new ethers.Wallet(privateKey);

// Access the address property
console.log("Address:", wallet.address);
