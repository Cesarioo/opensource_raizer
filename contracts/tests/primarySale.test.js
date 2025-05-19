const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("PrimarySale", function () {
  // Increase timeout for complex operations
  this.timeout(60000);

  async function deployFixture() {
    const [owner, addr1, addr2, addr3, ...addrs] = await ethers.getSigners();

    // Deploy MockUSD (USD token)
    console.log("\nDeploying MockUSD...");
    const MockUSDFactory = await ethers.getContractFactory("MockUSD");
    const usdToken = await MockUSDFactory.deploy();
    await usdToken.waitForDeployment();
    const usdAddress = await usdToken.getAddress();
    console.log("MockUSD Token deployed at:", usdAddress);

    // Deploy MockLZEndpoint first
    console.log("\nDeploying MockLZEndpoint...");
    const MockLZEndpointFactory = await ethers.getContractFactory("MockLZEndpoint");
    const mockLZEndpoint = await MockLZEndpointFactory.deploy(1); // Chain ID 1 for tests
    await mockLZEndpoint.waitForDeployment();
    const lzEndpointAddress = await mockLZEndpoint.getAddress();
    console.log("MockLZEndpoint deployed at:", lzEndpointAddress);

    // Deploy MyOFT (Token to be sold)
    console.log("\nDeploying MyOFT (Sale Token)...");
    const MyOFTFactory = await ethers.getContractFactory("MyOFT");
    const saleToken = await MyOFTFactory.deploy(
      "Sale Token", 
      "SALE", 
      0, // No initial supply
      lzEndpointAddress, // Use the mock LZ endpoint instead of addr3
      owner.address, // delegate
      owner.address  // admin
    );
    await saleToken.waitForDeployment();
    const saleTokenAddress = await saleToken.getAddress();
    console.log("Sale Token deployed at:", saleTokenAddress);

    // Deploy Whitelist contract
    console.log("\nDeploying Whitelist...");
    const WhitelistFactory = await ethers.getContractFactory("contracts/production_ready/whitelist.sol:Whitelist");
    const whitelist = await WhitelistFactory.deploy(owner.address);
    await whitelist.waitForDeployment();
    const whitelistAddress = await whitelist.getAddress();
    console.log("Whitelist deployed at:", whitelistAddress);

    // Deploy PrimarySale contract
    console.log("\nDeploying PrimarySale...");
    const PrimarySaleFactory = await ethers.getContractFactory("PrimarySale");
    const primarySale = await PrimarySaleFactory.deploy(
      saleTokenAddress, 
      whitelistAddress,
      owner.address // admin
    );
    await primarySale.waitForDeployment();
    const saleAddress = await primarySale.getAddress();
    console.log("PrimarySale deployed at:", saleAddress);

    // Add PrimarySale as minter for sale token
    await saleToken.addMinter(saleAddress);

    return {
      usdToken,
      saleToken,
      whitelist,
      primarySale,
      owner,
      addr1,
      addr2,
      addr3,
      addrs
    };
  }

  describe("Contract Deployment", function () {
    it("Should deploy with correct initial state", async function () {
      const { primarySale, saleToken, whitelist } = await loadFixture(deployFixture);
      
      expect(await primarySale.token()).to.equal(await saleToken.getAddress());
      expect(await primarySale.whitelist()).to.equal(await whitelist.getAddress());
      expect(await primarySale.hasDistributedUSD()).to.be.false;
      expect(await primarySale.canMintTokens()).to.be.false;
      expect(await primarySale.totalShares()).to.equal(0);
    });

    it("Should set up minting permissions correctly", async function () {
      const { primarySale, saleToken } = await loadFixture(deployFixture);
      const saleAddress = await primarySale.getAddress();
      expect(await saleToken.hasRole(await saleToken.MINTER_ROLE(), saleAddress)).to.be.true;
    });
  });

  describe("Whitelist Management", function () {
    it("Should prevent non-whitelisted users from contributing", async function () {
      const { primarySale, usdToken, owner, addr1 } = await loadFixture(deployFixture);
      const contribution = ethers.parseUnits("150", 6); // Assuming 6 decimals for MockUSD
      const usdTokenAddress = await usdToken.getAddress();

      // Setup but don't whitelist
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);

      // Try to contribute without being whitelisted
      await expect(
        primarySale.connect(addr1).contribute(usdTokenAddress, contribution)
      ).to.be.revertedWithCustomError(primarySale, "NotWhitelisted");
    });

    it("Should allow whitelisted users to contribute", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const contribution = ethers.parseUnits("150", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Setup and whitelist
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      
      // Generate a UUID for the whitelist (using bytes16)
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);

      // Contribute after being whitelisted
      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);
      const normalizedContribution = await primarySale.getNormalizedContribution(addr1.address);
      expect(normalizedContribution).to.be.gt(0);
    });
  });

  describe("USD Token Management", function () {
    it("Should allow admin to add USD token", async function () {
      const { primarySale, owner } = await loadFixture(deployFixture);
      const MockUSDFactory = await ethers.getContractFactory("MockUSD");
      const newUsdToken = await MockUSDFactory.deploy();
      await newUsdToken.waitForDeployment();
      const newUsdAddress = await newUsdToken.getAddress();

      await primarySale.connect(owner).addUSDToken(newUsdAddress);
      expect(await primarySale.isUSDTokenAllowed(newUsdAddress)).to.be.true;
    });

    it("Should prevent non-admins from adding USD token", async function () {
      const { primarySale, addr1 } = await loadFixture(deployFixture);
      const MockUSDFactory = await ethers.getContractFactory("MockUSD");
      const newUsdToken = await MockUSDFactory.deploy();
      await newUsdToken.waitForDeployment();
      const newUsdAddress = await newUsdToken.getAddress();

      await expect(
        primarySale.connect(addr1).addUSDToken(newUsdAddress)
      ).to.be.revertedWithCustomError(
        primarySale, 
        "AccessControlUnauthorizedAccount"
      );
    });

    it("Should allow admin to remove USD token", async function () {
      const { primarySale, owner } = await loadFixture(deployFixture);
      const MockUSDFactory = await ethers.getContractFactory("MockUSD");
      const newUsdToken = await MockUSDFactory.deploy();
      await newUsdToken.waitForDeployment();
      const newUsdAddress = await newUsdToken.getAddress();

      await primarySale.connect(owner).addUSDToken(newUsdAddress);
      await primarySale.connect(owner).removeUSDToken(newUsdAddress);
      expect(await primarySale.isUSDTokenAllowed(newUsdAddress)).to.be.false;
    });

    it("Should prevent removing non-existent USD token", async function () {
      const { primarySale, owner } = await loadFixture(deployFixture);
      const MockUSDFactory = await ethers.getContractFactory("MockUSD");
      const newUsdToken = await MockUSDFactory.deploy();
      await newUsdToken.waitForDeployment();
      const newUsdAddress = await newUsdToken.getAddress();

      await expect(
        primarySale.connect(owner).removeUSDToken(newUsdAddress)
      ).to.be.revertedWithCustomError(primarySale, "USDTokenNotFound");
    });

    it("Should allow contributions with different USD tokens", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      
      // Generate a UUID for the whitelist (using bytes16)
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);
      
      // Deploy a second USD token
      const MockUSDFactory = await ethers.getContractFactory("MockUSD");
      const usd2Token = await MockUSDFactory.deploy();
      await usd2Token.waitForDeployment();
      const usd2Address = await usd2Token.getAddress();
      
      // Add both USD tokens
      await primarySale.connect(owner).addUSDToken(await usdToken.getAddress());
      await primarySale.connect(owner).addUSDToken(usd2Address);
      
      // Prepare contributions with second token only
      const contribution = ethers.parseUnits("50", 6);
      
      // Mint and approve token
      await usd2Token.mint(addr1.address, contribution);
      await usd2Token.connect(addr1).approve(await primarySale.getAddress(), contribution);
      
      // Contribute with second token
      await primarySale.connect(addr1).contribute(usd2Address, contribution);
      
      // Verify contribution was recorded
      const normalizedContribution = await primarySale.getNormalizedContribution(addr1.address);
      expect(normalizedContribution).to.be.gt(0);
      expect(await primarySale.totalNormalizedUSD()).to.equal(normalizedContribution);
    });
  });

  describe("Share Management", function () {
    it("Should allow admin to set total shares", async function () {
      const { primarySale, owner } = await loadFixture(deployFixture);
      const totalShares = 1000000; // 1 million shares

      await primarySale.connect(owner).setTotalShares(totalShares);
      expect(await primarySale.totalShares()).to.equal(totalShares);
    });

    it("Should prevent non-admin from setting total shares", async function () {
      const { primarySale, addr1 } = await loadFixture(deployFixture);
      const totalShares = 1000000;

      await expect(
        primarySale.connect(addr1).setTotalShares(totalShares)
      ).to.be.revertedWithCustomError(
        primarySale, 
        "AccessControlUnauthorizedAccount"
      );
    });

    it("Should not allow setting total shares after minting is enabled", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const totalShares = 1000000;
      const contribution = ethers.parseUnits("150", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist (using bytes16)
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);

      // Setup contribution first
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);

      // Set shares and enable minting
      await primarySale.connect(owner).setTotalShares(totalShares);
      await primarySale.connect(owner).distributeUSD([usdTokenAddress]);
      await primarySale.connect(owner).enableMinting();

      await expect(
        primarySale.connect(owner).setTotalShares(totalShares * 2)
      ).to.be.revertedWithCustomError(primarySale, "CannotChangeTotalSharesAfterMintingEnabled");
    });
  });

  describe("Contributions", function () {
    it("Should allow users to contribute USD", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const contribution = ethers.parseUnits("150", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist (using bytes16)
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);

      // Mint USD to addr1
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);

      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);
      const normalizedContribution = await primarySale.getNormalizedContribution(addr1.address);
      expect(normalizedContribution).to.be.gt(0);
    });

    it("Should track total USD collected", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1, addr2 } = await loadFixture(deployFixture);
      const contribution1 = ethers.parseUnits("150", 6);
      const contribution2 = ethers.parseUnits("250", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate UUIDs and whitelist both addresses
      const uuid1 = ethers.hexlify(ethers.randomBytes(16));
      const uuid2 = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid1);
      await whitelist.connect(owner).addToWhitelist(addr2.address, uuid2);

      // Setup contributions
      await usdToken.mint(addr1.address, contribution1);
      await usdToken.mint(addr2.address, contribution2);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution1);
      await usdToken.connect(addr2).approve(await primarySale.getAddress(), contribution2);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);

      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution1);
      await primarySale.connect(addr2).contribute(usdTokenAddress, contribution2);

      // Get the actual normalized total from the contract
      const totalNormalizedUSD = await primarySale.totalNormalizedUSD();
      
      // Verify the total is correct
      expect(totalNormalizedUSD).to.equal(await primarySale.getNormalizedContribution(addr1.address) + await primarySale.getNormalizedContribution(addr2.address));
    });

    it("Should prevent contributions after USD distribution", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const contribution = ethers.parseUnits("150", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);

      // First contribution
      await usdToken.mint(addr1.address, contribution * 2n);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution * 2n);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);

      // Distribute USD
      await primarySale.connect(owner).distributeUSD([usdTokenAddress]);

      // Try second contribution
      await expect(
        primarySale.connect(addr1).contribute(usdTokenAddress, contribution)
      ).to.be.revertedWithCustomError(primarySale, "USDAlreadyDistributed");
    });
  });

  describe("Token Distribution", function () {
    it("Should allow claiming correct token amount", async function () {
      const { primarySale, usdToken, whitelist, saleToken, owner, addr1 } = await loadFixture(deployFixture);
      const totalShares = 1000000; // 1 million shares
      const contribution = ethers.parseUnits("150", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);

      // Setup
      await primarySale.connect(owner).setTotalShares(totalShares);
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);

      // Get initial token balance
      const initialBalance = await saleToken.balanceOf(addr1.address);

      // Enable claiming
      await primarySale.connect(owner).distributeUSD([usdTokenAddress]);
      await primarySale.connect(owner).enableMinting();

      // Claim and verify
      await primarySale.connect(addr1).claim();
      expect(await primarySale.hasClaimed(addr1.address)).to.be.true;
      
      // Verify token balance increased
      expect(await saleToken.balanceOf(addr1.address)).to.be.gt(initialBalance);
    });

    it("Should prevent double claiming", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const totalShares = 1000000;
      const contribution = ethers.parseUnits("150", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);

      // Setup
      await primarySale.connect(owner).setTotalShares(totalShares);
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);
      await primarySale.connect(owner).distributeUSD([usdTokenAddress]);
      await primarySale.connect(owner).enableMinting();

      // First claim should succeed
      await primarySale.connect(addr1).claim();

      // Second claim should fail
      await expect(
        primarySale.connect(addr1).claim()
      ).to.be.revertedWithCustomError(primarySale, "AlreadyClaimed");
    });

    it("Should prevent claiming before minting is enabled", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const totalShares = 1000000;
      const contribution = ethers.parseUnits("150", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);

      // Setup without enabling minting
      await primarySale.connect(owner).setTotalShares(totalShares);
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);
      await primarySale.connect(owner).distributeUSD([usdTokenAddress]);

      // Attempt to claim
      await expect(
        primarySale.connect(addr1).claim()
      ).to.be.revertedWithCustomError(primarySale, "MintingNotEnabled");
    });
  });

  describe("Admin Functions", function () {
    it("Should allow admin to distribute USD", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const contribution = ethers.parseUnits("150", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);

      // Setup contribution
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);

      // Get initial balance of owner
      const initialBalance = await usdToken.balanceOf(owner.address);

      // Distribute USD
      await primarySale.connect(owner).distributeUSD([usdTokenAddress]);
      expect(await primarySale.hasDistributedUSD()).to.be.true;
      
      // Owner should receive the contributed amount
      expect(await usdToken.balanceOf(owner.address)).to.equal(initialBalance + contribution);
    });

    it("Should prevent distributing USD multiple times", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const contribution = ethers.parseUnits("150", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);

      // Setup contribution
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);

      // First distribution
      await primarySale.connect(owner).distributeUSD([usdTokenAddress]);

      // Try second distribution
      await expect(
        primarySale.connect(owner).distributeUSD([usdTokenAddress])
      ).to.be.revertedWithCustomError(primarySale, "USDAlreadyDistributed");
    });

    it("Should allow admin to pause and unpause the contract", async function () {
      const { primarySale, owner } = await loadFixture(deployFixture);
      
      // Initially not paused
      expect(await primarySale.paused()).to.be.false;
      
      // Pause
      await primarySale.connect(owner).pause();
      expect(await primarySale.paused()).to.be.true;
      
      // Unpause
      await primarySale.connect(owner).unpause();
      expect(await primarySale.paused()).to.be.false;
    });

    it("Should prevent actions when paused", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const contribution = ethers.parseUnits("150", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);
      
      // Setup
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      
      // Pause contract
      await primarySale.connect(owner).pause();
      
      // Try to contribute while paused - expect custom error "EnforcedPause"
      await expect(
        primarySale.connect(addr1).contribute(usdTokenAddress, contribution)
      ).to.be.revertedWithCustomError(primarySale, "EnforcedPause");
    });
  });

  describe("Edge Cases and Complex Scenarios", function () {
    it("Should handle zero USD contributions correctly", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const zeroContribution = ethers.parseUnits("0", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);
      
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await usdToken.mint(addr1.address, zeroContribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), zeroContribution);

      await expect(
        primarySale.connect(addr1).contribute(usdTokenAddress, zeroContribution)
      ).to.be.revertedWithCustomError(primarySale, "ZeroAmount");
    });

    it("Should handle large contributions within safe limits", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      // Use a large but safe value instead of MaxUint256
      const largeContribution = ethers.parseUnits("1000000000", 6); // 1 billion USD
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);
      
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await usdToken.mint(addr1.address, largeContribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), largeContribution);

      await primarySale.connect(addr1).contribute(usdTokenAddress, largeContribution);
      const normalizedContribution = await primarySale.getNormalizedContribution(addr1.address);
      expect(normalizedContribution).to.be.gt(0);
    });

    it("Should enforce non-zero total shares", async function () {
      const { primarySale, owner } = await loadFixture(deployFixture);
      const zeroShares = 0;

      await expect(
        primarySale.connect(owner).setTotalShares(zeroShares)
      ).to.be.revertedWithCustomError(primarySale, "ZeroAmount");
    });

    it("Should handle multiple contributions from same user with different tokens", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const contribution1 = ethers.parseUnits("100", 6);
      const contribution2 = ethers.parseUnits("150", 6);

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);
      
      // Deploy second USD token
      const MockUSDFactory = await ethers.getContractFactory("MockUSD");
      const usd2Token = await MockUSDFactory.deploy();
      await usd2Token.waitForDeployment();
      const usd2Address = await usd2Token.getAddress();

      // Setup first token
      await primarySale.connect(owner).addUSDToken(await usdToken.getAddress());
      await usdToken.mint(addr1.address, contribution1);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution1);
      
      // Setup second token
      await primarySale.connect(owner).addUSDToken(usd2Address);
      await usd2Token.mint(addr1.address, contribution2);
      await usd2Token.connect(addr1).approve(await primarySale.getAddress(), contribution2);

      // Contribute with first token
      await primarySale.connect(addr1).contribute(await usdToken.getAddress(), contribution1);
      
      // The second contribution with a different token should be rejected
      await expect(
        primarySale.connect(addr1).contribute(usd2Address, contribution2)
      ).to.be.revertedWithCustomError(
        primarySale, 
        "DifferentUSDTokenUsed"
      );
    });

    it("Should handle removal of USD token after contributions", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const contribution = ethers.parseUnits("100", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);
      
      // Setup
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);

      // Contribute then remove token
      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);
      await primarySale.connect(owner).removeUSDToken(usdTokenAddress);

      // Verify state
      expect(await primarySale.isUSDTokenAllowed(usdTokenAddress)).to.be.false;
      const normalizedContribution = await primarySale.getNormalizedContribution(addr1.address);
      expect(normalizedContribution).to.be.gt(0);
    });

    it("Should handle multiple whitelisting operations correctly", async function () {
      const { primarySale, whitelist, owner, addr1 } = await loadFixture(deployFixture);

      // Generate UUIDs for the whitelist
      const uuid1 = ethers.hexlify(ethers.randomBytes(16));
      const uuid2 = ethers.hexlify(ethers.randomBytes(16));

      // Add to whitelist
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid1);
      expect(await whitelist.isAddressWhitelisted(addr1.address)).to.be.true;

      // Remove from whitelist
      await whitelist.connect(owner).removeFromWhitelist(addr1.address);
      expect(await whitelist.isAddressWhitelisted(addr1.address)).to.be.false;

      // Add back to whitelist
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid2);
      expect(await whitelist.isAddressWhitelisted(addr1.address)).to.be.true;
    });

    it("Should prevent contributions with non-allowed USD tokens even if whitelisted", async function () {
      const { primarySale, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      
      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);
      
      // Deploy a new token that's not allowed
      const MockUSDFactory = await ethers.getContractFactory("MockUSD");
      const nonAllowedToken = await MockUSDFactory.deploy();
      await nonAllowedToken.waitForDeployment();
      const nonAllowedAddress = await nonAllowedToken.getAddress();
      
      // Try to contribute with non-allowed token
      const contribution = ethers.parseUnits("100", 6);
      await nonAllowedToken.mint(addr1.address, contribution);
      await nonAllowedToken.connect(addr1).approve(await primarySale.getAddress(), contribution);

      await expect(
        primarySale.connect(addr1).contribute(nonAllowedAddress, contribution)
      ).to.be.revertedWithCustomError(primarySale, "USDTokenNotAllowed");
    });

    it("Should prevent contribution after being removed from whitelist", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      const contribution = ethers.parseUnits("100", 6);
      const usdTokenAddress = await usdToken.getAddress();

      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);
      
      // Setup
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);

      // Remove from whitelist
      await whitelist.connect(owner).removeFromWhitelist(addr1.address);

      // Try to contribute
      await expect(
        primarySale.connect(addr1).contribute(usdTokenAddress, contribution)
      ).to.be.revertedWithCustomError(primarySale, "NotWhitelisted");
    });

    it("Should handle multiple USD token distributions correctly", async function () {
      const { primarySale, usdToken, whitelist, owner, addr1 } = await loadFixture(deployFixture);
      
      // Generate a UUID for the whitelist
      const uuid = ethers.hexlify(ethers.randomBytes(16));
      await whitelist.connect(owner).addToWhitelist(addr1.address, uuid);
      
      // Deploy multiple USD tokens
      const MockUSDFactory = await ethers.getContractFactory("MockUSD");
      const usd2Token = await MockUSDFactory.deploy();
      const usd3Token = await MockUSDFactory.deploy();
      await usd2Token.waitForDeployment();
      await usd3Token.waitForDeployment();

      const contribution = ethers.parseUnits("100", 6);
      const usdTokenAddress = await usdToken.getAddress();
      const usd2Address = await usd2Token.getAddress();
      const usd3Address = await usd3Token.getAddress();

      // Setup
      await primarySale.connect(owner).addUSDToken(usdTokenAddress);
      await primarySale.connect(owner).addUSDToken(usd2Address);
      await primarySale.connect(owner).addUSDToken(usd3Address);

      // Contribute with first token (can only use one token per contributor)
      await usdToken.mint(addr1.address, contribution);
      await usdToken.connect(addr1).approve(await primarySale.getAddress(), contribution);
      await primarySale.connect(addr1).contribute(usdTokenAddress, contribution);

      // Distribute all USD tokens (even though only one was contributed to)
      await primarySale.connect(owner).distributeUSD([usdTokenAddress, usd2Address, usd3Address]);

      // Verify balances - owner should receive the contributed amount
      expect(await usdToken.balanceOf(owner.address)).to.equal(contribution);
      // No contributions for these tokens, so balance shouldn't change
      expect(await usd2Token.balanceOf(owner.address)).to.equal(0);
      expect(await usd3Token.balanceOf(owner.address)).to.equal(0);
    });
  });
});
