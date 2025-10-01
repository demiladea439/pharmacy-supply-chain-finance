;; =============================================================================
;; PHARMA CAPITAL - PHARMACEUTICAL SUPPLY CHAIN FINANCE PLATFORM
;; =============================================================================
;; Verify pharmaceutical shipments and authenticity
;; Provide immediate supplier payments
;; Extend payment terms to pharmacies
;; Track drug inventory and expiration dates
;; Optimize working capital across pharmacy supply chains

;; =============================================================================
;; ERROR CODES
;; =============================================================================

(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_SHIPMENT (err u101))
(define-constant ERR_SHIPMENT_NOT_FOUND (err u102))
(define-constant ERR_ALREADY_PAID (err u103))
(define-constant ERR_PAYMENT_OVERDUE (err u104))
(define-constant ERR_INVALID_AMOUNT (err u105))
(define-constant ERR_INSUFFICIENT_BALANCE (err u106))
(define-constant ERR_DRUG_NOT_FOUND (err u107))
(define-constant ERR_EXPIRED_DRUG (err u108))
(define-constant ERR_INVALID_BATCH (err u109))
(define-constant ERR_PHARMACY_NOT_FOUND (err u110))
(define-constant ERR_SUPPLIER_NOT_FOUND (err u111))
(define-constant ERR_INVALID_TERMS (err u112))

;; =============================================================================
;; CONSTANTS
;; =============================================================================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant MAX_PAYMENT_TERMS_DAYS u90) ;; 90 days maximum payment terms
(define-constant MIN_PAYMENT_TERMS_DAYS u30) ;; 30 days minimum payment terms
(define-constant LATE_FEE_RATE u500) ;; 5% late fee rate (basis points)
(define-constant PRECISION u10000) ;; 100.00% = 10000
(define-constant BLOCKS_PER_DAY u144) ;; Approximate blocks per day
(define-constant MAX_SHIPMENTS u10000)

;; =============================================================================
;; DATA STRUCTURES
;; =============================================================================

;; Pharmaceutical drug information
(define-map drugs
  { drug-id: uint }
  {
    name: (string-ascii 128),
    ndc-number: (string-ascii 32), ;; National Drug Code
    manufacturer: (string-ascii 64),
    dosage-form: (string-ascii 32),
    strength: (string-ascii 32),
    controlled-substance: bool,
    requires-refrigeration: bool,
    active: bool
  }
)

;; Registered pharmacies
(define-map pharmacies
  { pharmacy-id: principal }
  {
    name: (string-ascii 128),
    license-number: (string-ascii 32),
    dea-number: (optional (string-ascii 16)),
    address: (string-ascii 256),
    credit-limit: uint,
    payment-terms-days: uint,
    total-outstanding: uint,
    registration-date: uint,
    active: bool
  }
)

;; Registered suppliers
(define-map suppliers
  { supplier-id: principal }
  {
    name: (string-ascii 128),
    license-number: (string-ascii 32),
    address: (string-ascii 256),
    bank-account: (string-ascii 64),
    total-supplied: uint,
    registration-date: uint,
    active: bool
  }
)

;; Pharmaceutical shipments
(define-map shipments
  { shipment-id: uint }
  {
    supplier: principal,
    pharmacy: principal,
    drug-id: uint,
    batch-number: (string-ascii 32),
    quantity: uint,
    unit-price: uint,
    total-amount: uint,
    manufacture-date: uint, ;; block height
    expiration-date: uint, ;; block height
    shipment-date: uint, ;; block height
    delivery-date: (optional uint), ;; block height
    payment-due-date: uint, ;; block height
    supplier-paid: bool,
    pharmacy-paid: bool,
    verified: bool,
    temperature-controlled: bool,
    tracking-number: (string-ascii 64)
  }
)

;; Inventory tracking
(define-map inventory
  { pharmacy: principal, drug-id: uint, batch-number: (string-ascii 32) }
  {
    quantity: uint,
    unit-price: uint,
    expiration-date: uint,
    received-date: uint,
    storage-temperature: (optional int)
  }
)

;; Payment schedules
(define-map payment-schedules
  { pharmacy: principal }
  {
    total-due: uint,
    next-payment-due: uint, ;; block height
    overdue-amount: uint,
    late-fees: uint,
    payment-terms: uint ;; days
  }
)

;; Drug recalls
(define-map drug-recalls
  { recall-id: uint }
  {
    drug-id: uint,
    batch-numbers: (list 10 (string-ascii 32)),
    recall-reason: (string-ascii 256),
    recall-date: uint,
    severity-level: uint, ;; 1-3 (1=most severe)
    active: bool
  }
)

;; =============================================================================
;; DATA VARIABLES
;; =============================================================================

(define-data-var next-drug-id uint u1)
(define-data-var next-shipment-id uint u1)
(define-data-var next-recall-id uint u1)
(define-data-var total-shipments uint u0)
(define-data-var total-value-processed uint u0)
(define-data-var platform-fees uint u0)
(define-data-var emergency-shutdown bool false)
(define-data-var regulatory-authority (optional principal) none)

;; =============================================================================
;; PRIVATE FUNCTIONS
;; =============================================================================

;; Calculate payment due date based on terms
(define-private (calculate-due-date (shipment-date uint) (payment-terms-days uint))
  (+ shipment-date (* payment-terms-days BLOCKS_PER_DAY))
)

;; Check if drug is expired
(define-private (is-drug-expired (expiration-date uint))
  (>= stacks-block-height expiration-date)
)

;; Calculate late fees
(define-private (calculate-late-fees (amount uint) (days-overdue uint))
  (let (
    (daily-rate (/ LATE_FEE_RATE u365))
    (total-rate (* daily-rate days-overdue))
  )
    (/ (* amount total-rate) PRECISION)
  )
)

;; Validate NDC format (simplified)
(define-private (validate-ndc (ndc (string-ascii 32)))
  (and (> (len ndc) u0) (<= (len ndc) u32))
)

;; Update pharmacy outstanding balance
(define-private (update-pharmacy-balance (pharmacy-id principal) (amount uint) (add bool))
  (match (map-get? pharmacies { pharmacy-id: pharmacy-id })
    pharmacy-data
    (let (
      (current-outstanding (get total-outstanding pharmacy-data))
      (new-outstanding (if add 
                        (+ current-outstanding amount)
                        (if (>= current-outstanding amount)
                          (- current-outstanding amount)
                          u0)))
    )
      (map-set pharmacies
        { pharmacy-id: pharmacy-id }
        (merge pharmacy-data { total-outstanding: new-outstanding })
      )
      (ok new-outstanding)
    )
    ERR_PHARMACY_NOT_FOUND
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS - ADMIN
;; =============================================================================

;; Register a new drug in the system
(define-public (register-drug
  (name (string-ascii 128))
  (ndc-number (string-ascii 32))
  (manufacturer (string-ascii 64))
  (dosage-form (string-ascii 32))
  (strength (string-ascii 32))
  (controlled-substance bool)
  (requires-refrigeration bool)
)
  (let (
    (drug-id (var-get next-drug-id))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (validate-ndc ndc-number) ERR_INVALID_BATCH)
    (asserts! (> (len name) u0) ERR_INVALID_AMOUNT)
    
    (map-set drugs
      { drug-id: drug-id }
      {
        name: name,
        ndc-number: ndc-number,
        manufacturer: manufacturer,
        dosage-form: dosage-form,
        strength: strength,
        controlled-substance: controlled-substance,
        requires-refrigeration: requires-refrigeration,
        active: true
      }
    )
    
    (var-set next-drug-id (+ drug-id u1))
    (ok drug-id)
  )
)

;; Register a new pharmacy
(define-public (register-pharmacy
  (pharmacy-id principal)
  (name (string-ascii 128))
  (license-number (string-ascii 32))
  (dea-number (optional (string-ascii 16)))
  (address (string-ascii 256))
  (credit-limit uint)
  (payment-terms-days uint)
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (and (>= payment-terms-days MIN_PAYMENT_TERMS_DAYS)
                  (<= payment-terms-days MAX_PAYMENT_TERMS_DAYS)) ERR_INVALID_TERMS)
    (asserts! (> credit-limit u0) ERR_INVALID_AMOUNT)
    
    (map-set pharmacies
      { pharmacy-id: pharmacy-id }
      {
        name: name,
        license-number: license-number,
        dea-number: dea-number,
        address: address,
        credit-limit: credit-limit,
        payment-terms-days: payment-terms-days,
        total-outstanding: u0,
        registration-date: stacks-block-height,
        active: true
      }
    )
    
    (ok true)
  )
)

;; Register a new supplier
(define-public (register-supplier
  (supplier-id principal)
  (name (string-ascii 128))
  (license-number (string-ascii 32))
  (address (string-ascii 256))
  (bank-account (string-ascii 64))
)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    
    (map-set suppliers
      { supplier-id: supplier-id }
      {
        name: name,
        license-number: license-number,
        address: address,
        bank-account: bank-account,
        total-supplied: u0,
        registration-date: stacks-block-height,
        active: true
      }
    )
    
    (ok true)
  )
)

;; Set regulatory authority
(define-public (set-regulatory-authority (authority principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set regulatory-authority (some authority))
    (ok true)
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS - CORE FUNCTIONALITY
;; =============================================================================

;; Create a new pharmaceutical shipment
(define-public (create-shipment
  (pharmacy-id principal)
  (drug-id uint)
  (batch-number (string-ascii 32))
  (quantity uint)
  (unit-price uint)
  (manufacture-date uint)
  (expiration-date uint)
  (temperature-controlled bool)
  (tracking-number (string-ascii 64))
)
  (let (
    (shipment-id (var-get next-shipment-id))
    (total-amount (* quantity unit-price))
    (pharmacy-data (unwrap! (map-get? pharmacies { pharmacy-id: pharmacy-id }) ERR_PHARMACY_NOT_FOUND))
    (supplier-data (unwrap! (map-get? suppliers { supplier-id: tx-sender }) ERR_SUPPLIER_NOT_FOUND))
    (drug-data (unwrap! (map-get? drugs { drug-id: drug-id }) ERR_DRUG_NOT_FOUND))
    (payment-due-date (calculate-due-date stacks-block-height (get payment-terms-days pharmacy-data)))
  )
    ;; Validation checks
    (asserts! (not (var-get emergency-shutdown)) ERR_UNAUTHORIZED)
    (asserts! (get active pharmacy-data) ERR_PHARMACY_NOT_FOUND)
    (asserts! (get active supplier-data) ERR_SUPPLIER_NOT_FOUND)
    (asserts! (get active drug-data) ERR_DRUG_NOT_FOUND)
    (asserts! (> quantity u0) ERR_INVALID_AMOUNT)
    (asserts! (> unit-price u0) ERR_INVALID_AMOUNT)
    (asserts! (> expiration-date stacks-block-height) ERR_EXPIRED_DRUG)
    (asserts! (<= (+ (get total-outstanding pharmacy-data) total-amount) 
                 (get credit-limit pharmacy-data)) ERR_INSUFFICIENT_BALANCE)
    (asserts! (< (var-get total-shipments) MAX_SHIPMENTS) ERR_INVALID_SHIPMENT)
    
    ;; Check temperature requirements
    (asserts! (or (not (get requires-refrigeration drug-data)) temperature-controlled) ERR_INVALID_SHIPMENT)
    
    ;; Create shipment
    (map-set shipments
      { shipment-id: shipment-id }
      {
        supplier: tx-sender,
        pharmacy: pharmacy-id,
        drug-id: drug-id,
        batch-number: batch-number,
        quantity: quantity,
        unit-price: unit-price,
        total-amount: total-amount,
        manufacture-date: manufacture-date,
        expiration-date: expiration-date,
        shipment-date: stacks-block-height,
        delivery-date: none,
        payment-due-date: payment-due-date,
        supplier-paid: false,
        pharmacy-paid: false,
        verified: false,
        temperature-controlled: temperature-controlled,
        tracking-number: tracking-number
      }
    )
    
    ;; Update pharmacy outstanding balance
    (try! (update-pharmacy-balance pharmacy-id total-amount true))
    
    ;; Update global counters
    (var-set next-shipment-id (+ shipment-id u1))
    (var-set total-shipments (+ (var-get total-shipments) u1))
    
    (ok shipment-id)
  )
)

;; Verify and confirm shipment delivery
(define-public (confirm-delivery (shipment-id uint))
  (match (map-get? shipments { shipment-id: shipment-id })
    shipment
    (let (
      (pharmacy-data (unwrap! (map-get? pharmacies { pharmacy-id: (get pharmacy shipment) }) ERR_PHARMACY_NOT_FOUND))
    )
      (asserts! (is-eq tx-sender (get pharmacy shipment)) ERR_UNAUTHORIZED)
      (asserts! (not (get verified shipment)) ERR_ALREADY_PAID)
      
      ;; Update shipment as verified and delivered
      (map-set shipments
        { shipment-id: shipment-id }
        (merge shipment {
          delivery-date: (some stacks-block-height),
          verified: true
        })
      )
      
      ;; Add to pharmacy inventory
      (map-set inventory
        { pharmacy: (get pharmacy shipment), drug-id: (get drug-id shipment), batch-number: (get batch-number shipment) }
        {
          quantity: (get quantity shipment),
          unit-price: (get unit-price shipment),
          expiration-date: (get expiration-date shipment),
          received-date: stacks-block-height,
          storage-temperature: (if (get temperature-controlled shipment) (some 2) none) ;; 2C for refrigerated
        }
      )
      
      (ok true)
    )
    ERR_SHIPMENT_NOT_FOUND
  )
)

;; Pay supplier immediately upon verified delivery
(define-public (pay-supplier (shipment-id uint))
  (match (map-get? shipments { shipment-id: shipment-id })
    shipment
    (begin
      (asserts! (get verified shipment) ERR_INVALID_SHIPMENT)
      (asserts! (not (get supplier-paid shipment)) ERR_ALREADY_PAID)
      
      ;; Transfer payment to supplier
      (try! (stx-transfer? (get total-amount shipment) (as-contract tx-sender) (get supplier shipment)))
      
      ;; Mark as paid
      (map-set shipments
        { shipment-id: shipment-id }
        (merge shipment { supplier-paid: true })
      )
      
      ;; Update global statistics
      (var-set total-value-processed (+ (var-get total-value-processed) (get total-amount shipment)))
      
      (ok (get total-amount shipment))
    )
    ERR_SHIPMENT_NOT_FOUND
  )
)

;; Process pharmacy payment
(define-public (process-pharmacy-payment (payment-amount uint))
  (let (
    (pharmacy-data (unwrap! (map-get? pharmacies { pharmacy-id: tx-sender }) ERR_PHARMACY_NOT_FOUND))
    (current-outstanding (get total-outstanding pharmacy-data))
  )
    (asserts! (> payment-amount u0) ERR_INVALID_AMOUNT)
    (asserts! (<= payment-amount current-outstanding) ERR_INVALID_AMOUNT)
    
    ;; Transfer payment from pharmacy
    (try! (stx-transfer? payment-amount tx-sender (as-contract tx-sender)))
    
    ;; Update pharmacy balance
    (try! (update-pharmacy-balance tx-sender payment-amount false))
    
    (ok payment-amount)
  )
)

;; Issue drug recall
(define-public (issue-drug-recall
  (drug-id uint)
  (batch-numbers (list 10 (string-ascii 32)))
  (recall-reason (string-ascii 256))
  (severity-level uint)
)
  (let (
    (recall-id (var-get next-recall-id))
  )
    (asserts! (or (is-eq tx-sender CONTRACT_OWNER)
                 (is-eq (some tx-sender) (var-get regulatory-authority))) ERR_UNAUTHORIZED)
    (asserts! (and (>= severity-level u1) (<= severity-level u3)) ERR_INVALID_AMOUNT)
    
    (map-set drug-recalls
      { recall-id: recall-id }
      {
        drug-id: drug-id,
        batch-numbers: batch-numbers,
        recall-reason: recall-reason,
        recall-date: stacks-block-height,
        severity-level: severity-level,
        active: true
      }
    )
    
    (var-set next-recall-id (+ recall-id u1))
    (ok recall-id)
  )
)

;; =============================================================================
;; READ-ONLY FUNCTIONS
;; =============================================================================

;; Get drug information
(define-read-only (get-drug (drug-id uint))
  (map-get? drugs { drug-id: drug-id })
)

;; Get pharmacy information
(define-read-only (get-pharmacy (pharmacy-id principal))
  (map-get? pharmacies { pharmacy-id: pharmacy-id })
)

;; Get supplier information
(define-read-only (get-supplier (supplier-id principal))
  (map-get? suppliers { supplier-id: supplier-id })
)

;; Get shipment information
(define-read-only (get-shipment (shipment-id uint))
  (map-get? shipments { shipment-id: shipment-id })
)

;; Get inventory for pharmacy
(define-read-only (get-inventory (pharmacy principal) (drug-id uint) (batch-number (string-ascii 32)))
  (map-get? inventory { pharmacy: pharmacy, drug-id: drug-id, batch-number: batch-number })
)

;; Get payment schedule for pharmacy
(define-read-only (get-payment-schedule (pharmacy principal))
  (map-get? payment-schedules { pharmacy: pharmacy })
)

;; Get recall information
(define-read-only (get-recall (recall-id uint))
  (map-get? drug-recalls { recall-id: recall-id })
)

;; Check if drug batch is recalled
(define-read-only (is-batch-recalled (drug-id uint) (batch-number (string-ascii 32)))
  (let (
    (recall-check (map-get? drug-recalls { recall-id: u1 })) ;; Simplified - would need to iterate
  )
    (match recall-check
      recall-data
      (and 
        (is-eq (get drug-id recall-data) drug-id)
        (get active recall-data)
      )
      false
    )
  )
)

;; Get platform statistics
(define-read-only (get-platform-stats)
  (ok {
    total-shipments: (var-get total-shipments),
    total-value-processed: (var-get total-value-processed),
    platform-fees: (var-get platform-fees),
    next-drug-id: (var-get next-drug-id),
    next-shipment-id: (var-get next-shipment-id),
    emergency-shutdown: (var-get emergency-shutdown)
  })
)

;; Check shipment payment status
(define-read-only (get-payment-status (shipment-id uint))
  (match (map-get? shipments { shipment-id: shipment-id })
    shipment
    (ok {
      shipment-id: shipment-id,
      supplier-paid: (get supplier-paid shipment),
      pharmacy-paid: (get pharmacy-paid shipment),
      verified: (get verified shipment),
      total-amount: (get total-amount shipment),
      payment-due-date: (get payment-due-date shipment),
      is-overdue: (> stacks-block-height (get payment-due-date shipment))
    })
    ERR_SHIPMENT_NOT_FOUND
  )
)

;; Check drug expiration status
(define-read-only (check-drug-expiration (pharmacy principal) (drug-id uint) (batch-number (string-ascii 32)))
  (match (map-get? inventory { pharmacy: pharmacy, drug-id: drug-id, batch-number: batch-number })
    inv-data
    (ok {
      drug-id: drug-id,
      batch-number: batch-number,
      expiration-date: (get expiration-date inv-data),
      is-expired: (is-drug-expired (get expiration-date inv-data)),
      days-until-expiry: (if (> (get expiration-date inv-data) stacks-block-height)
                          (/ (- (get expiration-date inv-data) stacks-block-height) BLOCKS_PER_DAY)
                          u0)
    })
    ERR_DRUG_NOT_FOUND
  )
)
