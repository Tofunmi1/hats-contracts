// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "./Base.sol";

contract Claim is Base {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    //_descriptionHash - a hash of an ipfs encrypted file which describe the claim.
    // this can be use later on by the claimer to prove her claim
    function logClaim(string memory _descriptionHash) external payable {
        if (generalParameters.claimFee > 0) {
            if (msg.value < generalParameters.claimFee)
                revert NotEnoughFeePaid();
            // solhint-disable-next-line indent
            payable(owner()).transfer(msg.value);
        }
        emit LogClaim(msg.sender, _descriptionHash);
    }

    /**
    * @notice Called by a committee to submit a claim for a bounty.
    * The submitted claim needs to be approved or dismissed by the Hats governance.
    * This function should be called only on a safety period, where withdrawals are disabled.
    * Upon a call to this function by the committee the pool withdrawals will be disabled
    * until the Hats governance will approve or dismiss this claim.
    * @param _pid The pool id
    * @param _beneficiary The submitted claim's beneficiary
    * @param _bountyPercentage The submitted claim's bug requested reward percentage
    */
    function submitClaim(uint256 _pid,
        address _beneficiary,
        uint256 _bountyPercentage,
        string calldata _descriptionHash)
    external
    onlyCommittee(_pid)
    noActiveClaims(_pid)
    {
        if (_beneficiary == address(0)) revert BeneficiaryIsZero();
        // require we are in safetyPeriod
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp % (generalParameters.withdrawPeriod + generalParameters.safetyPeriod) <
        generalParameters.withdrawPeriod) revert NotSafetyPeriod();
        if (_bountyPercentage > bountyInfos[_pid].maxBounty)
            revert BountyPercentageHigherThanMaxBounty();
        uint256 claimId;
        claimId = uint256(keccak256(abi.encodePacked(_pid, block.number, nonce++)));
        claims[claimId] = Claim({
            pid: _pid,
            beneficiary: _beneficiary,
            bountyPercentage: _bountyPercentage,
            committee: msg.sender,
            // solhint-disable-next-line not-rely-on-time
            createdAt: block.timestamp,
            isChallenged: false
        });
        activeClaims[_pid] = claimId;
        emit SubmitClaim(
            _pid,
            claimId,
            msg.sender,
            _beneficiary,
            _bountyPercentage,
            _descriptionHash
        );
    }

    function challengeClaim(uint256 _claimId) external onlyArbitrator {
        if (claims[_claimId].beneficiary == address(0))
            revert NoActiveClaimExists();
        claims[_claimId].isChallenged = true;
    }

    /**
    * @notice Approve a claim for a bounty submitted by a committee, and transfer bounty to hacker and committee.
    * callable by the  arbitrator, if isChallenged == true
    * Callable by anyone after challengePeriod is passed and isChallenged == false
    * @param _claimId The claim ID
    */
    function approveClaim(uint256 _claimId, uint256 _bountyPercentage) external nonReentrant {
        Claim storage claim = claims[_claimId];
        if (claim.beneficiary == address(0)) revert NoActiveClaimExists();
        if (!(msg.sender == arbitrator && claim.isChallenged) &&
            (claim.createdAt + challengePeriod > block.timestamp))
        revert ClaimCanOnlyBeApprovedAfterChallengePeriodOrByArbitrator();

        if (msg.sender == arbitrator) {
            claim.bountyPercentage = _bountyPercentage;
        }
        uint256 pid = claim.pid;
        BountyInfo storage bountyInfo = bountyInfos[pid];
        IERC20Upgradeable lpToken = poolInfos[pid].lpToken;
        ClaimBounty memory claimBounty = calcClaimBounty(pid, claim.bountyPercentage);
        poolInfos[pid].balance -= claimBounty.hacker
            + claimBounty.hackerVested
            + claimBounty.committee
            + claimBounty.swapAndBurn
            + claimBounty.hackerHatVested
            + claimBounty.governanceHat;
        address tokenLock;
        if (claimBounty.hackerVested > 0) {
        //hacker gets part of bounty to a vesting contract
            tokenLock = tokenLockFactory.createTokenLock(
            address(lpToken),
            0x000000000000000000000000000000000000dEaD, //this address as owner, so it can do nothing.
            claim.beneficiary,
            claimBounty.hackerVested,
            // solhint-disable-next-line not-rely-on-time
            block.timestamp, //start
            // solhint-disable-next-line not-rely-on-time
            block.timestamp + bountyInfo.vestingDuration, //end
            bountyInfo.vestingPeriods,
            0, //no release start
            0, //no cliff
            ITokenLock.Revocability.Disabled,
            false
            );
            lpToken.safeTransfer(tokenLock, claimBounty.hackerVested);
        }
        lpToken.safeTransfer(claim.beneficiary, claimBounty.hacker);
        lpToken.safeTransfer(claim.committee, claimBounty.committee);
        //storing the amount of token which can be swap and burned so it could be swapAndBurn in a separate tx.
        swapAndBurns[pid] += claimBounty.swapAndBurn;
        governanceHatRewards[pid] += claimBounty.governanceHat;
        hackersHatRewards[claim.beneficiary][pid] += claimBounty.hackerHatVested;
        // emit event before deleting the claim object, bcause we want to read beneficiary and bountyPercentage
        emit ApproveClaim(pid,
            _claimId,
            msg.sender,
            claim.beneficiary,
            claim.bountyPercentage,
            tokenLock,
            claimBounty);
        delete activeClaims[pid];
        delete claims[_claimId];
    }

    /**
    * @notice Dismiss a claim for a bounty submitted by a committee.
    * Called either by Hats governance, or by anyone if the claim is over 5 weeks old.
    * @param _claimId The claim ID
    */
    function dismissClaim(uint256 _claimId) external {
        Claim storage claim = claims[_claimId];
        uint256 pid = claim.pid;
        // solhint-disable-next-line not-rely-on-time
        if (!(msg.sender == arbitrator && claim.isChallenged) &&
            (claim.createdAt + challengeTimeOutPeriod > block.timestamp))
            revert OnlyCallableByGovernanceOrAfterChallengeTimeOutPeriod();
        if (claim.beneficiary == address(0)) revert NoActiveClaimExists();
        delete activeClaims[pid];
        delete claims[_claimId];
        emit DismissClaim(pid, _claimId);
    }


    function calcClaimBounty(uint256 _pid, uint256 _bountyPercentage)
    public
    view
    returns(ClaimBounty memory claimBounty) {
        uint256 totalSupply = poolInfos[_pid].balance;
        if (totalSupply == 0) revert PoolBalanceIsZero();
        if (_bountyPercentage > bountyInfos[_pid].maxBounty)
            revert BountyPercentageHigherThanMaxBounty();
        uint256 totalBountyAmount = totalSupply * _bountyPercentage;
        claimBounty.hackerVested =
        totalBountyAmount * bountyInfos[_pid].bountySplit.hackerVested
        / (HUNDRED_PERCENT * HUNDRED_PERCENT);
        claimBounty.hacker =
        totalBountyAmount * bountyInfos[_pid].bountySplit.hacker
        / (HUNDRED_PERCENT * HUNDRED_PERCENT);
        claimBounty.committee =
        totalBountyAmount * bountyInfos[_pid].bountySplit.committee
        / (HUNDRED_PERCENT * HUNDRED_PERCENT);
        claimBounty.swapAndBurn =
        totalBountyAmount * bountyInfos[_pid].bountySplit.swapAndBurn
        / (HUNDRED_PERCENT * HUNDRED_PERCENT);
        claimBounty.governanceHat =
        totalBountyAmount * bountyInfos[_pid].bountySplit.governanceHat
        / (HUNDRED_PERCENT * HUNDRED_PERCENT);
        claimBounty.hackerHatVested =
        totalBountyAmount * bountyInfos[_pid].bountySplit.hackerHatVested
        / (HUNDRED_PERCENT * HUNDRED_PERCENT);
    }
}
