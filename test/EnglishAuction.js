require("dotenv").config()
const PUBLIC_KEY = process.env.PUBLIC_KEY
const { expect } = require("chai");
const {
  expectEvent
} = require('@openzeppelin/test-helpers');

describe("EnglishAuction contract", function () {
  it("Auction should work as an English Auction", async function () {
    const [owner, addr1, addr2] = await ethers.getSigners();

    // deploy NFT on hardhat network
    const MyNFT = await ethers.getContractFactory("MyNFT")
    const myNFT = await MyNFT.deploy()
    await myNFT.deployed()
    // console.log("Contract deployed to address:", myNFT.address)

    // mint NFT(s)
    const tx = await myNFT.mintNFT(owner.address, "test")
    const receipt = await tx.wait()
    const event = receipt.events.find(x => x.event === "nftMinted")
    const mintedTokenId = event.args.tokenId
    // console.log("mint recipient:", event.args._to)
    console.log("token owner after mint:", await myNFT.ownerOf(mintedTokenId))
    // console.log(event.args.tokenId)

    // expect(await myNFT.mintNFT(PUBLIC_KEY, "test"))
    //   .to.emit(myNFT, "nftMinted")
    //   .withArgs(PUBLIC_KEY, 1);
    // const nftID2 = await myNFT.mintNFT(PUBLIC_KEY, "test2")
    
    // deploy EnglishAuction
    const AuctionFactory = await ethers.getContractFactory("EnglishAuction");
    const startingBid = 1
    const hardhatAuction = await AuctionFactory.deploy(myNFT.address, mintedTokenId, startingBid)
    const nftId = await hardhatAuction.nftId()
    const seller = await hardhatAuction.seller()
    // console.log("Auction nft id:", nftId)
    // console.log("Auction seller:", seller)
    // console.log("AuctionFactory address:", AuctionFactory.signer.address)

    // start EnglishAuction
    await hardhatAuction.start()
    expect(await hardhatAuction.started()).to.equal(true)

    // first bid
    const bid1 = ethers.utils.parseEther("0.5")
    await hardhatAuction.connect(addr1).bid({ value: bid1 })
    expect(await hardhatAuction.highestBid()).to.equal(bid1)
    expect(await hardhatAuction.highestBidder()).to.equal(addr1.address)

    // second bid
    const bid2 = ethers.utils.parseEther("0.75")
    await hardhatAuction.connect(addr2).bid({ value: bid2 })
    expect(await hardhatAuction.highestBid()).to.equal(bid2)
    expect(await hardhatAuction.highestBidder()).to.equal(addr2.address)

    // failed bid
    await expect(hardhatAuction.connect(addr2).bid({ value: bid1 })).to.be.reverted
    expect(await hardhatAuction.highestBid()).to.equal(bid2)
    expect(await hardhatAuction.highestBidder()).to.equal(addr2.address)


    // console.log(hardhatAuction.address);
    // console.log(owner.address);
    // const seller = await hardhatAuction.getSeller();
    // expect(seller).to.equal(owner.address);
    // const started = await hardhatAuction.getStarted();
    // console.log(started);
    // await hardhatAuction.start();
    // expect(await hardhatAuction.started()).to.equal(true);
    // console.log(await nftContract.methods.ownerOf(1))
    // let nftOwner;
    // await nftContract.methods.ownerOf(1).call(function (err, res) {
    //   if (err) {
    //     console.log("An error occured", err)
    //     return
    //   }
    //   console.log("The owner is", res)
    //   nftOwner = res
      
    // })
    // console.log(hardhatAuction.address)
    // expect(nftOwner).to.equal(hardhatAuction.address);


    // // Transfer 50 tokens from addr1 to addr2
    // await hardhatToken.connect(addr1).transfer(addr2.address, 50);
    // expect(await hardhatToken.balanceOf(addr2.address)).to.equal(50);
  });
});