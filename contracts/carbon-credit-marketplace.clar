;; carbon-credit-marketplace
;; 
;; This contract serves as the central hub for all carbon credit operations on the Stacks blockchain.
;; It manages registration of verified carbon credit issuers, minting of carbon credits as tokens, 
;; facilitating trades between buyers and sellers, and the retirement of credits when claiming offsets.
;; 
;; Each credit token represents one ton of CO2 equivalent that has been reduced, avoided, or
;; removed from the atmosphere through verified environmental projects.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-ISSUER-ALREADY-REGISTERED (err u101))
(define-constant ERR-ISSUER-NOT-REGISTERED (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-INVALID-AMOUNT (err u104))
(define-constant ERR-LISTING-NOT-FOUND (err u105))
(define-constant ERR-LISTING-EXPIRED (err u106))
(define-constant ERR-ALREADY-OWNER (err u107))
(define-constant ERR-CREDIT-NOT-FOUND (err u108))
(define-constant ERR-CREDIT-ALREADY-RETIRED (err u109))
(define-constant ERR-INVALID-BID (err u110))
(define-constant ERR-BID-TOO-LOW (err u111))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant PLATFORM-FEE-PERCENTAGE u2) ;; 2% fee
(define-constant RETIREMENT-PREFIX "RETIRED")

;; Data structures

;; Track registered issuers who can mint carbon credits
(define-map issuers
  { issuer: principal }
  {
    name: (string-ascii 100),
    verified: bool,
    verification-date: uint,
    total-credits-issued: uint
  }
)

;; Carbon credit data - each credit has project metadata and status
(define-map carbon-credits
  { credit-id: uint }
  {
    issuer: principal,
    project-name: (string-ascii 100),
    project-location: (string-ascii 100),
    vintage-year: uint,
    verification-standard: (string-ascii 50),
    impact-type: (string-ascii 50),  ;; e.g., "Reforestation", "Renewable Energy"
    retired: bool,
    retirement-beneficiary: (optional principal),
    retirement-date: (optional uint)
  }
)

;; Market listings of credits for sale
(define-map credit-listings
  { listing-id: uint }
  {
    seller: principal,
    credit-id: uint,
    price: uint,
    expiry: uint,  ;; block height for expiration
    active: bool
  }
)

;; Bids placed on credits
(define-map credit-bids
  { bid-id: uint }
  {
    bidder: principal,
    credit-id: uint,
    amount: uint,
    expiry: uint,  ;; block height for expiration
    active: bool
  }
)

;; Certificate issued when credits are retired
(define-map retirement-certificates
  { certificate-id: uint }
  {
    owner: principal,
    credit-ids: (list 100 uint),
    retirement-date: uint,
    certificate-uri: (string-ascii 256)
  }
)

;; Ownership tracking - which principal owns which credits and how many
(define-map credit-ownership
  { owner: principal, credit-id: uint }
  { amount: uint }
)

;; Auto-incrementing counters
(define-data-var next-credit-id uint u1)
(define-data-var next-listing-id uint u1)
(define-data-var next-bid-id uint u1)
(define-data-var next-certificate-id uint u1)

;; Total platform stats
(define-data-var total-credits-minted uint u0)
(define-data-var total-credits-retired uint u0)
(define-data-var total-volume-traded uint u0)

;; Private functions

;; Check if the caller is the contract owner
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

;; Check if the caller is a registered issuer
(define-private (is-registered-issuer (issuer principal))
  (default-to false (get verified (map-get? issuers { issuer: issuer })))
)

;; Update credit ownership when transfers occur
(define-private (update-credit-ownership (owner principal) (credit-id uint) (amount uint) (add bool))
  (let (
    (current-amount (default-to u0 (get amount (map-get? credit-ownership { owner: owner, credit-id: credit-id }))))
    (new-amount (if add
                   (+ current-amount amount)
                   (- current-amount amount)))
  )
    (map-set credit-ownership
      { owner: owner, credit-id: credit-id }
      { amount: new-amount }
    )
    (ok new-amount)
  )
)

;; Calculate platform fee for a transaction
(define-private (calculate-fee (amount uint))
  (/ (* amount PLATFORM-FEE-PERCENTAGE) u100)
)

;; Generate a certificate URI - would typically connect to IPFS or similar
(define-private (generate-certificate-uri (certificate-id uint))
  (concat 
    "https://carbonmint.xyz/certificates/" 
    (to-ascii (+ certificate-id))
  )
)

;; Check if a credit exists and is not retired
(define-private (is-valid-active-credit (credit-id uint))
  (match (map-get? carbon-credits { credit-id: credit-id })
    credit (not (get retired credit))
    false
  )
)

;; Public functions

;; Register a new carbon credit issuer - can only be called by contract owner
(define-public (register-issuer (issuer principal) (name (string-ascii 100)))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (is-none (map-get? issuers { issuer: issuer })) ERR-ISSUER-ALREADY-REGISTERED)
    
    (map-set issuers
      { issuer: issuer }
      {
        name: name,
        verified: true,
        verification-date: block-height,
        total-credits-issued: u0
      }
    )
    (ok true)
  )
)

;; Mint new carbon credits - can only be called by registered issuers
(define-public (mint-carbon-credits 
  (project-name (string-ascii 100))
  (project-location (string-ascii 100))
  (vintage-year uint)
  (verification-standard (string-ascii 50))
  (impact-type (string-ascii 50))
  (amount uint))
  
  (let ((credit-id (var-get next-credit-id))
        (issuer tx-sender))
    (asserts! (is-registered-issuer issuer) ERR-ISSUER-NOT-REGISTERED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Create the carbon credit
    (map-set carbon-credits
      { credit-id: credit-id }
      {
        issuer: issuer,
        project-name: project-name,
        project-location: project-location,
        vintage-year: vintage-year,
        verification-standard: verification-standard,
        impact-type: impact-type,
        retired: false,
        retirement-beneficiary: none,
        retirement-date: none
      }
    )
    
    ;; Update issuer's total credits issued
    (map-set issuers
      { issuer: issuer }
      (merge 
        (unwrap-panic (map-get? issuers { issuer: issuer }))
        { total-credits-issued: (+ amount (get total-credits-issued (unwrap-panic (map-get? issuers { issuer: issuer })))) }
      )
    )
    
    ;; Assign ownership to the issuer
    (update-credit-ownership issuer credit-id amount true)
    
    ;; Update global counters
    (var-set next-credit-id (+ credit-id u1))
    (var-set total-credits-minted (+ (var-get total-credits-minted) amount))
    
    (ok credit-id)
  )
)

;; List carbon credits for sale
(define-public (list-credits-for-sale (credit-id uint) (amount uint) (price uint) (expiry uint))
  (let ((listing-id (var-get next-listing-id))
        (seller tx-sender))
    
    ;; Validation checks
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (> price u0) ERR-INVALID-AMOUNT)
    (asserts! (>= expiry block-height) ERR-LISTING-EXPIRED)
    
    ;; Check ownership
    (asserts! (>= (default-to u0 (get amount (map-get? credit-ownership { owner: seller, credit-id: credit-id }))) amount) 
              ERR-INSUFFICIENT-FUNDS)
    
    ;; Check if credit is valid and not retired
    (asserts! (is-valid-active-credit credit-id) ERR-CREDIT-ALREADY-RETIRED)
    
    ;; Create listing
    (map-set credit-listings
      { listing-id: listing-id }
      {
        seller: seller,
        credit-id: credit-id,
        price: price,
        expiry: expiry,
        active: true
      }
    )
    
    ;; Update counter
    (var-set next-listing-id (+ listing-id u1))
    
    (ok listing-id)
  )
)

;; Purchase listed carbon credits
(define-public (purchase-credits (listing-id uint))
  (let (
    (listing (unwrap! (map-get? credit-listings { listing-id: listing-id }) ERR-LISTING-NOT-FOUND))
    (seller (get seller listing))
    (credit-id (get credit-id listing))
    (price (get price listing))
    (active (get active listing))
    (expiry (get expiry listing))
    (buyer tx-sender)
    (platform-fee (calculate-fee price))
    (seller-amount (- price platform-fee))
  )
    ;; Validation checks
    (asserts! active ERR-LISTING-NOT-FOUND)
    (asserts! (<= block-height expiry) ERR-LISTING-EXPIRED)
    (asserts! (not (is-eq buyer seller)) ERR-ALREADY-OWNER)
    
    ;; Check if credit is still valid
    (asserts! (is-valid-active-credit credit-id) ERR-CREDIT-ALREADY-RETIRED)
    
    ;; Transfer STX from buyer to seller and platform
    (try! (stx-transfer? price buyer seller))
    (try! (stx-transfer? platform-fee buyer CONTRACT-OWNER))
    
    ;; Update ownership
    (try! (update-credit-ownership seller credit-id u1 false))
    (try! (update-credit-ownership buyer credit-id u1 true))
    
    ;; Mark listing as inactive
    (map-set credit-listings
      { listing-id: listing-id }
      (merge listing { active: false })
    )
    
    ;; Update platform stats
    (var-set total-volume-traded (+ (var-get total-volume-traded) price))
    
    (ok true)
  )
)

;; Retire carbon credits (take them out of circulation)
(define-public (retire-credits (credit-id uint) (amount uint) (beneficiary (optional principal)))
  (let (
    (owner tx-sender)
    (actual-beneficiary (default-to owner beneficiary))
    (retirement-date block-height)
    (certificate-id (var-get next-certificate-id))
  )
    ;; Validation checks
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Check ownership
    (asserts! (>= (default-to u0 (get amount (map-get? credit-ownership { owner: owner, credit-id: credit-id }))) amount) 
              ERR-INSUFFICIENT-FUNDS)
    
    ;; Check if credit exists
    (asserts! (is-some (map-get? carbon-credits { credit-id: credit-id })) ERR-CREDIT-NOT-FOUND)
    
    ;; Check if credit is not already retired
    (asserts! (is-valid-active-credit credit-id) ERR-CREDIT-ALREADY-RETIRED)
    
    ;; Update credit status
    (map-set carbon-credits
      { credit-id: credit-id }
      (merge 
        (unwrap-panic (map-get? carbon-credits { credit-id: credit-id }))
        { 
          retired: true,
          retirement-beneficiary: (some actual-beneficiary),
          retirement-date: (some retirement-date)
        }
      )
    )
    
    ;; Remove from owner's balance
    (try! (update-credit-ownership owner credit-id amount false))
    
    ;; Create retirement certificate
    (map-set retirement-certificates
      { certificate-id: certificate-id }
      {
        owner: actual-beneficiary,
        credit-ids: (list credit-id),
        retirement-date: retirement-date,
        certificate-uri: (generate-certificate-uri certificate-id)
      }
    )
    
    ;; Update counters
    (var-set next-certificate-id (+ certificate-id u1))
    (var-set total-credits-retired (+ (var-get total-credits-retired) amount))
    
    (ok certificate-id)
  )
)

;; Place a bid on carbon credits
(define-public (place-bid (credit-id uint) (amount uint) (expiry uint))
  (let (
    (bid-id (var-get next-bid-id))
    (bidder tx-sender)
  )
    ;; Validation checks
    (asserts! (> amount u0) ERR-INVALID-BID)
    (asserts! (>= expiry block-height) ERR-LISTING-EXPIRED)
    
    ;; Verify credit exists
    (asserts! (is-some (map-get? carbon-credits { credit-id: credit-id })) ERR-CREDIT-NOT-FOUND)
    
    ;; Check if credit is not retired
    (asserts! (is-valid-active-credit credit-id) ERR-CREDIT-ALREADY-RETIRED)
    
    ;; Create bid
    (map-set credit-bids
      { bid-id: bid-id }
      {
        bidder: bidder,
        credit-id: credit-id,
        amount: amount,
        expiry: expiry,
        active: true
      }
    )
    
    ;; Update counter
    (var-set next-bid-id (+ bid-id u1))
    
    (ok bid-id)
  )
)

;; Accept a bid for carbon credits
(define-public (accept-bid (bid-id uint))
  (let (
    (bid (unwrap! (map-get? credit-bids { bid-id: bid-id }) ERR-LISTING-NOT-FOUND))
    (bidder (get bidder bid))
    (credit-id (get credit-id bid))
    (bid-amount (get amount bid))
    (expiry (get expiry bid))
    (active (get active bid))
    (seller tx-sender)
    (platform-fee (calculate-fee bid-amount))
    (seller-amount (- bid-amount platform-fee))
  )
    ;; Validation checks
    (asserts! active ERR-LISTING-NOT-FOUND)
    (asserts! (<= block-height expiry) ERR-LISTING-EXPIRED)
    
    ;; Check ownership
    (asserts! (>= (default-to u0 (get amount (map-get? credit-ownership { owner: seller, credit-id: credit-id }))) u1) 
              ERR-INSUFFICIENT-FUNDS)
    
    ;; Check if credit is not retired
    (asserts! (is-valid-active-credit credit-id) ERR-CREDIT-ALREADY-RETIRED)
    
    ;; Transfer STX from bidder to seller and platform
    (try! (stx-transfer? bid-amount bidder seller))
    (try! (stx-transfer? platform-fee seller CONTRACT-OWNER))
    
    ;; Update ownership
    (try! (update-credit-ownership seller credit-id u1 false))
    (try! (update-credit-ownership bidder credit-id u1 true))
    
    ;; Mark bid as inactive
    (map-set credit-bids
      { bid-id: bid-id }
      (merge bid { active: false })
    )
    
    ;; Update platform stats
    (var-set total-volume-traded (+ (var-get total-volume-traded) bid-amount))
    
    (ok true)
  )
)

;; Cancel a listing
(define-public (cancel-listing (listing-id uint))
  (let (
    (listing (unwrap! (map-get? credit-listings { listing-id: listing-id }) ERR-LISTING-NOT-FOUND))
    (seller (get seller listing))
  )
    ;; Ensure only the seller can cancel
    (asserts! (is-eq tx-sender seller) ERR-NOT-AUTHORIZED)
    ;; Ensure listing is active
    (asserts! (get active listing) ERR-LISTING-NOT-FOUND)
    
    ;; Mark listing as inactive
    (map-set credit-listings
      { listing-id: listing-id }
      (merge listing { active: false })
    )
    
    (ok true)
  )
)

;; Cancel a bid
(define-public (cancel-bid (bid-id uint))
  (let (
    (bid (unwrap! (map-get? credit-bids { bid-id: bid-id }) ERR-LISTING-NOT-FOUND))
    (bidder (get bidder bid))
  )
    ;; Ensure only the bidder can cancel
    (asserts! (is-eq tx-sender bidder) ERR-NOT-AUTHORIZED)
    ;; Ensure bid is active
    (asserts! (get active bid) ERR-LISTING-NOT-FOUND)
    
    ;; Mark bid as inactive
    (map-set credit-bids
      { bid-id: bid-id }
      (merge bid { active: false })
    )
    
    (ok true)
  )
)

;; Read-only functions

;; Get carbon credit details
(define-read-only (get-credit-details (credit-id uint))
  (map-get? carbon-credits { credit-id: credit-id })
)

;; Get listing details
(define-read-only (get-listing-details (listing-id uint))
  (map-get? credit-listings { listing-id: listing-id })
)

;; Get bid details
(define-read-only (get-bid-details (bid-id uint))
  (map-get? credit-bids { bid-id: bid-id })
)

;; Get retirement certificate details
(define-read-only (get-certificate-details (certificate-id uint))
  (map-get? retirement-certificates { certificate-id: certificate-id })
)

;; Check credit ownership
(define-read-only (get-credit-balance (owner principal) (credit-id uint))
  (default-to u0 (get amount (map-get? credit-ownership { owner: owner, credit-id: credit-id })))
)

;; Get issuer details
(define-read-only (get-issuer-details (issuer principal))
  (map-get? issuers { issuer: issuer })
)

;; Get marketplace stats
(define-read-only (get-marketplace-stats)
  {
    total-credits-minted: (var-get total-credits-minted),
    total-credits-retired: (var-get total-credits-retired),
    total-volume-traded: (var-get total-volume-traded)
  }
)