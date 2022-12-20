// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "hardhat/console.sol";
 
interface IERC721 {
   function safeTransferFrom(
       address from,
       address to,
       uint tokenId
   ) external;
 
   function transferFrom(
       address,
       address,
       uint
   ) external;
   
   function ownerOf(uint256 tokenId) external view returns (address owner);
}
 
contract EnglishAuction {
   event Start();
   event Bid(address indexed sender, uint amount);
   event Withdraw(address indexed bidder, uint amount);
   event End(address winner, uint amount);
 
   IERC721 public nft;
   uint public nftId;
 
   address payable public seller;
   uint public endAt;
   bool public started;
   bool public ended;
 
   address public highestBidder;
   uint public highestBid;
   mapping(address => uint) public bids;
 
   constructor(
       address _nft,
       uint _nftId,
       uint _startingBid
   ) {
       nft = IERC721(_nft);
       nftId = _nftId;
 
       seller = payable(msg.sender);
       highestBid = _startingBid;
   }
//     // functions to test if constructor works
//    function getSeller() external view returns (address payable) {
//     return seller;
//    }

//    function getNftId() external view returns (uint) {
//     return nftId;
//    }


   // function to test if constructor works
   function getStarted() external view returns (bool) {
    return started;
   }

   function start() external {
    // console.log("msg.sender of start:", msg.sender);
    // console.log("nftId:", nftId);
       require(!started, "started");
       require(msg.sender == seller, "not seller");
    //    console.log("nft owner:", nft.ownerOf(nftId));
    //    console.log("address(this):", address(this));
    //    nft.transferFrom(msg.sender, address(this), nftId);
       started = true;
       endAt = block.timestamp + 7 days;
 
       emit Start();
   }

 
   function bid() external payable {
       require(started, "not started");
       require(block.timestamp < endAt, "ended");
       require(msg.value > highestBid, "value < highest");
 
       if (highestBidder != address(0)) {
           bids[highestBidder] += highestBid;
       }
 
       highestBidder = msg.sender;
       highestBid = msg.value;
 
       emit Bid(msg.sender, msg.value);
   }
 
   function withdraw() external {
       uint bal = bids[msg.sender];
       bids[msg.sender] = 0;
       payable(msg.sender).transfer(bal);
 
       emit Withdraw(msg.sender, bal);
   }
 
   function end() external {
       require(started, "not started");
       require(block.timestamp >= endAt, "not ended");
       require(!ended, "ended");
 
       ended = true;
       if (highestBidder != address(0)) {
           nft.safeTransferFrom(address(this), highestBidder, nftId);
           seller.transfer(highestBid);
       } else {
           nft.safeTransferFrom(address(this), seller, nftId);
       }
 
       emit End(highestBidder, highestBid);
   }
}
