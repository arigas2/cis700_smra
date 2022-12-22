// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "solmate/src/utils/ReentrancyGuard.sol";
import "solmate/src/utils/SafeTransferLib.sol";
import "solmate/src/tokens/ERC721.sol";
import "./SMRAErrors.sol";


/// @title A simulator for trees
/// @author Ruifan Wang, Leo Zheng, Andrew Rigas
/// @notice draws from https://github.com/a16z/auction-zoo/tree/main/src/sealed-bid/over-collateralized-auction

contract SimultaneousMultiRoundAuction is SMRAErrors, ReentrancyGuard{
    using SafeTransferLib for address;

    /// @dev Representation of an auction in storage.
    /// @param seller The address selling the auctioned asset.
    /// @param startTime The unix timestamp at which bidding can start.
    /// @param endOfBiddingPeriod The unix timestamp after which bids can no
    ///        longer be placed.
    /// @param endOfRevealPeriod The unix timestamp after which commitments can
    ///        no longer be opened.
    /// @param firstBiddingPeriod bid period specified when auction is created
    /// @param firstRevealPeriod reveal period specified when auction is created
    /// @param numUnrevealedBids The number of bid commitments that have not
    ///        yet been opened.
    /// @param highestBids For each item, the value of the highest bid revealed so far,
    ///        or the reserve price if no bids have exceeded it
    ///        This needs to map from tokenId to highest bid,
    ///        since there are multiple items in an auction (change from a16z implementation)
    /// @param highestBidders For each item, the bidder that placed the highest bid
    ///        This needs to map from tokenId to highest bidder,
    ///        since there are multiple items in an auction (change from a16z implementation).
    /// @param index Auctions selling the same asset (i.e. tokenContract-tokenId
    ///        pair) share the same storage. This value is incremented for 
    ///        each new auction of a particular asset.
    struct Auction {
        address seller;
        uint32 startTime;
        uint32 endOfBiddingPeriod;
        uint32 endOfRevealPeriod;
        uint32 firstBiddingPeriod;
        uint32 firstRevealPeriod;
        // =====================
        uint64 numUnrevealedBids;
        mapping(uint256 => uint96) highestBids;
        // =====================
        mapping(uint256 => address) highestBidders;
        uint64 index;
    }

    /// @dev Representation of a bid in storage. Occupies one slot.
    /// @param commitment The hash commitment of a bid value. 
    ///        WARNING: The hash is truncated to 20 bytes (160 bits) to save one 
    ///        storage slot. This weakens the security, and it is theoretically
    ///        feasible to generate two bids with different values that hash to
    ///        the same 20-byte value (h/t kchalkias for flagging this issue:
    ///        https://github.com/a16z/auction-zoo/issues/2). This would allow a 
    ///        bidder to effectively withdraw their bid at the last minute, once
    ///        other bids have been revealed. Currently, the computational cost of
    ///        such an attack would likely be prohibitvely high –– as of June 2021, 
    ///        researchers estimated that finding such a collision would cost ~$10B. 
    ///        If computational costs falls to the extent that this attack is a 
    ///        concern, it is possible to further mitigate the possibility of such 
    ///        an attack by using the full 32-byte hash value for the bid commitment. 
    /// @param collateral The amount of collateral backing the bid.
    /// @param revealed Whether the user has revealed the bid (necessary for multi round format).
    struct Bid {
        bytes20 commitment;
        uint96 collateral;
        bool revealed;
    }

    struct itemSet {
        uint256[] tokenIds;
    }

    /// @notice Emitted when an auction is created.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenIds The ERC721 token IDs of the assets being auctioned.
    /// @param seller The address selling the auctioned asset.
    /// @param startTime The unix timestamp at which bidding can start.
    /// @param bidPeriod The duration of the bidding period, in seconds.
    /// @param revealPeriod The duration of the commitment reveal period, 
    ///        in seconds.
    /// @param reservePrice The minimum price that the asset will be sold for.
    ///        If no bids exceed this price, the asset is returned to `seller`.
    event AuctionCreated(
        address tokenContract,
        uint256[] tokenIds,
        address seller,
        uint32 startTime,
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint96 reservePrice
    );

    /// @notice Emitted when a bid commitment is opened.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenIds The ERC721 token IDs of the assets being auctioned.
    /// @param commitment The commitment that was opened.
    /// @param bidder The bidder whose bid was revealed.
    /// @param nonce The random input used to obfuscate the commitment.
    /// @param bidValue The value of the bid.
    event BidRevealed(
        address tokenContract,
        bytes32 tokenIds,
        bytes20 commitment,
        address bidder,
        bytes32 nonce,
        uint96 bidValue
    );

    /// @notice A mapping storing auction parameters and state, indexed by
    ///         the ERC721 contract address and a hash (instead of single token ID as in a16z implementation)
    ///         of the token IDs of the assets being auctioned.
    ///         A hash for the multi-item auction is needed because a mapping key cannot be an array or struct.
    mapping(address => mapping(bytes32 => Auction)) public auctions;

    /// @notice A mapping storing bid commitments and records of collateral, 
    ///         indexed by: ERC721 contract address, hash of token IDs, auction index, 
    ///         specific token ID, and bidder address. If the commitment is `bytes20(0)`, either
    ///         no commitment was made or the commitment was opened.
    ///         In addition to hash of token ids, this state variable mapping includes
    ///         a specific token ID that a bid is placed on, modifying the a16z implementation.
    mapping(address // ERC721 token contract
        => mapping(bytes32 // ERC721 token IDs
            => mapping(uint64 // Auction index
                => mapping(uint256 // specific ERC token ID of item
                    => mapping(address // Bidder
                        => Bid))))) public bids;

    uint64 bidCounter = 0;

    /// @notice Creates an auction for the given ERC721 assets with the given
    ///         auction parameters.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenIds The ERC721 token IDs of the assets being auctioned.
    /// @param startTime The unix timestamp at which bidding can start.
    /// @param bidPeriod The duration of the bidding period, in seconds.
    /// @param revealPeriod The duration of the commitment reveal period, 
    ///        in seconds.
    /// @param reservePrice The minimum price that the asset will be sold for.
    ///        If no bids exceed this price, the asset is returned to `seller`.
    function createAuction(
        address tokenContract,
        uint256[] calldata tokenIds,
        uint32 startTime, 
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint96 reservePrice
    )
        external
        nonReentrant
    {
        bytes32 itemHash = keccak256(abi.encodePacked(tokenIds));
        Auction storage auction = auctions[tokenContract][itemHash];

        if (startTime == 0) {
            startTime = uint32(block.timestamp);
        } else if (startTime < block.timestamp) {
            revert InvalidStartTimeError(startTime);
        }
        if (bidPeriod < 1 hours) {
            revert BidPeriodTooShortError(bidPeriod);
        }
        if (revealPeriod < 1 hours) {
            revert RevealPeriodTooShortError(revealPeriod);
        }
        
        auction.seller = msg.sender;
        auction.startTime = startTime;
        auction.endOfBiddingPeriod = startTime + bidPeriod;
        auction.endOfRevealPeriod = startTime + bidPeriod + revealPeriod;
        auction.firstBiddingPeriod = bidPeriod;
        auction.firstRevealPeriod = revealPeriod;

        for (uint i = 0; i < tokenIds.length; i++) {
            // Resets
            // Highest bid is set to the reserve price.
            // Any winning bid must be at least this price, and the winner will 
             // pay at least this price.
            auction.highestBids[tokenIds[i]] = reservePrice;
            auction.highestBidders[tokenIds[i]] = address(0);
            ERC721(tokenContract).transferFrom(msg.sender, address(this), tokenIds[i]);
        }
        // Increment auction index for this item
        auction.index++;

        emit AuctionCreated(
            tokenContract,
            tokenIds,
            msg.sender,
            startTime,
            bidPeriod,
            revealPeriod,
            reservePrice
        );
    }

    /// @notice Commits to a bid on an one item being auctioned out of the list of items in tokenIds. If a bid was
    ///         previously committed to, overwrites the previous commitment.
    ///         Value attached to this call is used as collateral for the bid.
    ///         Modifying the a16z implementation, sets the bid as unrevealed.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenIds The hash of ERC721 token IDs of the assets being auctioned.
    /// @param specificTokenId The specific item (ERC721 token ID) to be bid on.
    /// @param commitment The commitment to the bid, computed as
    ///        `bytes20(keccak256(abi.encode(nonce, bidValue, tokenContract, tokenIds, specifictokenId, auctionIndex)))`.
    function commitBid(
        address tokenContract, 
        bytes32 tokenIds,
        uint256 specificTokenId, 
        bytes20 commitment
    )
        external
        payable
        nonReentrant
    {
        if (commitment == bytes20(0)) {
            revert ZeroCommitmentError();
        }

        Auction storage auction = auctions[tokenContract][tokenIds];

        if (
            block.timestamp < auction.startTime || 
            block.timestamp > auction.endOfBiddingPeriod
        ) {
            revert NotInBidPeriodError();
        }

        uint64 auctionIndex = auction.index;
        Bid storage bid = bids[tokenContract][tokenIds][auctionIndex][specificTokenId][msg.sender];
        // If this is the bidder's first commitment, increment `numUnrevealedBids`.
        if (bid.commitment == bytes20(0)) {
            auction.numUnrevealedBids++;
            bid.revealed = true;
        }
        if (!bid.revealed) {
            revert NotRevealedError();
        }
        bid.commitment = commitment;
        // set revealed to false, which allows bidders to cal the second withdraw func
        bid.revealed = false;
        if (msg.value != 0) {
            bid.collateral += uint96(msg.value);
        }
    }


    /// @notice Reveals the value of a bid that was previously committed to. 
    ///         Unlike in a16z implementation, non-highest bidder collateral is not
    ///         returned in this function, since there can be another bidding round.
    ///         User must call withdrawCollateral() to do so.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        being auctioned.
    /// @param tokenIds The hash of ERC721 token IDs of the assets being auctioned.
    /// @param specificTokenId The specific ERC721 token ID being bid on.
    /// @param bidValue The value of the bid.
    /// @param nonce The random input used to obfuscate the commitment.
    function revealBid(
        address tokenContract,
        bytes32 tokenIds,
        uint256 specificTokenId,
        uint96 bidValue,
        bytes32 nonce
    )
        external
        nonReentrant
    {
        Auction storage auction = auctions[tokenContract][tokenIds];

        if (
            block.timestamp <= auction.endOfBiddingPeriod ||
            block.timestamp > auction.endOfRevealPeriod
        ) {
            revert NotInRevealPeriodError();
        }

        uint64 auctionIndex = auction.index;
        Bid storage bid = bids[tokenContract][tokenIds][auctionIndex][specificTokenId][msg.sender];

        // Check that the opening is valid
        bytes20 bidHash = bytes20(keccak256(abi.encode(
            nonce,
            bidValue,
            tokenContract,
            tokenIds,
            specificTokenId,
            auctionIndex
        )));
        if (bidHash != bid.commitment) {
            revert InvalidOpeningError(bidHash, bid.commitment);
        } else {
            // Mark commitment as open
            bid.commitment = bytes20(0);
            // Mark bid as being revealed;
            bid.revealed = true;
            auction.numUnrevealedBids--;
        }

        uint96 collateral = bid.collateral;
        if (collateral < bidValue) {
            // Return collateral if its less than the value user committed to bid
            bid.collateral = 0;
            msg.sender.safeTransferETH(collateral);
        } else {
            bidCounter += 1;
            // Update record of highest bid as necessary
            uint96 currentHighestBid = auction.highestBids[specificTokenId];
            if (bidValue > currentHighestBid) {
                auction.highestBids[specificTokenId] = bidValue;
                auction.highestBidders[specificTokenId] = msg.sender;
            }

            emit BidRevealed(
                tokenContract,
                tokenIds,
                bidHash,
                msg.sender,
                nonce,
                bidValue
            );
        }
    }

    /// @notice Ends an active round. Can only end a round if the bid reveal
    ///         phase is over, or if all bids have been revealed.
    ///         If there are no revealed bids:      
    ///         Disburses the auction proceeds to the seller. Transfers the auctioned asset to the winning
    ///         bidder and returns any excess collateral. If no bidder exceeded the
    ///         auction's reserve price, returns the asset to the seller.
    ///         Otherwise, sets up next round with specified arguments,
    ///         or uses arguments from createAuction().
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenIds The hash of ERC721 token IDs of the assets auctioned.
    /// @param startTime The unix timestamp at which bidding can start, if there is new round.
    /// @param bidPeriod The duration of the bidding period, in seconds, if there is new round.
    /// @param revealPeriod The duration of the commitment reveal period, 
    ///        in seconds (if there is new round).

    function endRound(
        address tokenContract,
        uint256[] calldata tokenIds,
        bytes32 hashTokenIds,
        uint32 startTime, 
        uint32 bidPeriod,
        uint32 revealPeriod)
        external
        nonReentrant
    {
        Auction storage auction = auctions[tokenContract][hashTokenIds];
        if (auction.index == 0) {
            revert InvalidAuctionIndexError(0);
        }

        if (block.timestamp <= auction.endOfBiddingPeriod) {
            revert BidPeriodOngoingError();
        } else if (block.timestamp <= auction.endOfRevealPeriod) {
            if (auction.numUnrevealedBids != 0) {
                // cannot end auction early unless all bids have been revealed
                revert RevealPeriodOngoingError();
            }
        }

        // if (!newRound) {
        if (bidCounter == 0) {
            // no new bids that round so end auction
            for (uint i = 0; i < tokenIds.length; i++) {
                /// TODO: double check specificTokenId?
                uint256 specificTokenId = tokenIds[i];
                address itemHighestBidder = auction.highestBidders[specificTokenId];
                if (itemHighestBidder == address(0)) {
                    // No winner, return asset to seller.
                    ERC721(tokenContract).safeTransferFrom(address(this), auction.seller, specificTokenId);
                } else {
                    Bid storage bid = bids[tokenContract][hashTokenIds][auction.index][specificTokenId][itemHighestBidder];
                    if (!bid.revealed) {
                        revert NotRevealedError();
                    }
                    // Transfer auctioned asset to highest bidder
                    ERC721(tokenContract).safeTransferFrom(address(this), itemHighestBidder, specificTokenId);
                    uint96 itemHighestBid = auction.highestBids[specificTokenId];
                    auction.seller.safeTransferETH(itemHighestBid);

                    // Return excess collateral
                    uint96 collateral = bid.collateral;
                    bid.collateral = 0;
                    if (collateral - itemHighestBid != 0) {
                        itemHighestBidder.safeTransferETH(collateral - itemHighestBid);
                    }
                }
            }
        } else { // reset timing for next round
            if (startTime == 0) {
            startTime = uint32(block.timestamp);
            } else if (startTime < block.timestamp) {
                revert InvalidStartTimeError(startTime);
            }
            if (bidPeriod == 0) {
                bidPeriod = auction.firstBiddingPeriod;
            } else if (bidPeriod < 1 hours) {
                revert BidPeriodTooShortError(bidPeriod);
            }
            if (revealPeriod == 0) {
                revealPeriod = auction.firstRevealPeriod;
            } else if (revealPeriod < 1 hours) {
                revert RevealPeriodTooShortError(revealPeriod);
            }
            auction.startTime = startTime;
            auction.endOfBiddingPeriod = startTime + bidPeriod;
            auction.endOfRevealPeriod = startTime + bidPeriod + revealPeriod;
            bidCounter = 0;
        }
    }

    /// @notice Withdraws collateral. Bidder must have opened their bid commitment
    ///         and cannot be in the running to win the auction.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        that was auctioned.
    /// @param tokenIds The hash of ERC721 token IDs of the assets that was auctioned.
    /// @param auctionIndex The index of the auction that was being bid on.
    function withdrawCollateral(
        address tokenContract,
        bytes32 tokenIds,
        uint64 auctionIndex,
        uint256 specificTokenId
    )
        external
        nonReentrant        
    {
        Auction storage auction = auctions[tokenContract][tokenIds];
        uint64 currentAuctionIndex = auction.index;
        if (auctionIndex > currentAuctionIndex) {
            revert InvalidAuctionIndexError(auctionIndex);
        }

        Bid storage bid = bids[tokenContract][tokenIds][auctionIndex][specificTokenId][msg.sender];
        if (bid.commitment != bytes20(0)) {
            revert UnrevealedBidError();
        }

        if (auctionIndex == currentAuctionIndex) {
            // If bidder has revealed their bid and is not currently in the 
            // running to win the auction, they can withdraw their collateral.
            if (msg.sender == auction.highestBidders[specificTokenId]) {
                revert CannotWithdrawError();    
            }
        }
        // Return collateral
        uint96 collateral = bid.collateral;
        bid.collateral = 0;
        msg.sender.safeTransferETH(collateral);
    }

    /// @notice Withdraws collateral. Bidder must have opened their bid commitment
    ///         and this only applies to the period before revealing the bid.
    ///         This action is allowed in an SMRA, but not in the a16z implementation's auction format.
    /// @param tokenContract The address of the ERC721 contract for the asset
    ///        that was auctioned.
    /// @param tokenIds The hash of ERC721 token IDs of the assets being auctioned.
    /// @param auctionIndex The index of the auction that was being bid on.
    function withdrawCollateralBeforeReveal(
        address tokenContract,
        bytes32 tokenIds,
        uint64 auctionIndex,
        uint256 specificTokenId
    )
        external
        nonReentrant        
    {
        Auction storage auction = auctions[tokenContract][tokenIds];
        uint64 currentAuctionIndex = auction.index;
        if (auctionIndex > currentAuctionIndex) {
            revert InvalidAuctionIndexError(auctionIndex);
        }

        Bid storage bid = bids[tokenContract][tokenIds][auctionIndex][specificTokenId][msg.sender];
        if (bid.commitment != bytes20(0)) {
            revert UnrevealedBidError();
        }

        if (auctionIndex == currentAuctionIndex) {
            // If bidder has commited but not revealed their bid, they can withdraw their collateral.
            if (bid.revealed) {
                revert WithdrawAfterRevealError();    
            }
        }
        // Return collateral
        uint96 collateral = bid.collateral;
        bid.collateral = 0;
        msg.sender.safeTransferETH(collateral);
    }

    /// @notice Gets the parameters and state of an auction in storage.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenIds The ERC721 token ID of the asset auctioned.
    function getAuction(address tokenContract, bytes32 tokenIds)
        internal
        view
        returns (Auction storage auction)
    {
        return auctions[tokenContract][tokenIds];
    }
}