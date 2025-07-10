;; Repair Service Contract
;; Handles cushion replacement and frame restoration

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_NOT_FOUND (err u101))
(define-constant ERR_INVALID_INPUT (err u102))
(define-constant ERR_INSUFFICIENT_FUNDS (err u103))
(define-constant ERR_ALREADY_EXISTS (err u104))

;; Data Variables
(define-data-var next-repair-id uint u1)
(define-data-var next-provider-id uint u1)
(define-data-var min-provider-deposit uint u15000)

;; Data Maps
(define-map repair-requests
  uint
  {
    customer: principal,
    furniture-type: (string-ascii 50),
    repair-type: (string-ascii 50),
    description: (string-ascii 500),
    urgency: uint,
    max-budget: uint,
    assigned-provider: (optional principal),
    status: (string-ascii 20),
    quote-amount: uint,
    completion-date: (optional uint),
    warranty-period: uint,
    created-at: uint
  }
)

(define-map repair-providers
  principal
  {
    name: (string-ascii 100),
    specialties: (string-ascii 200),
    service-area: (string-ascii 100),
    rating: uint,
    total-repairs: uint,
    active: bool,
    deposit: uint,
    certification-level: uint
  }
)

(define-map repair-quotes
  {repair-id: uint, provider: principal}
  {
    quote-amount: uint,
    estimated-days: uint,
    warranty-months: uint,
    materials-included: bool,
    quote-notes: (string-ascii 300),
    submitted-at: uint
  }
)

(define-map repair-history
  uint
  {
    before-photos: (string-ascii 200),
    after-photos: (string-ascii 200),
    materials-used: (string-ascii 300),
    work-performed: (string-ascii 500),
    customer-rating: (optional uint),
    provider-notes: (string-ascii 300)
  }
)

;; Public Functions

;; Register repair provider
(define-public (register-repair-provider
  (name (string-ascii 100))
  (specialties (string-ascii 200))
  (service-area (string-ascii 100))
  (certification-level uint)
  (deposit uint)
)
  (begin
    (asserts! (>= deposit (var-get min-provider-deposit)) ERR_INSUFFICIENT_FUNDS)
    (asserts! (is-none (map-get? repair-providers tx-sender)) ERR_ALREADY_EXISTS)
    (asserts! (and (>= certification-level u1) (<= certification-level u3)) ERR_INVALID_INPUT)

    (try! (stx-transfer? deposit tx-sender (as-contract tx-sender)))

    (map-set repair-providers tx-sender {
      name: name,
      specialties: specialties,
      service-area: service-area,
      rating: u5,
      total-repairs: u0,
      active: true,
      deposit: deposit,
      certification-level: certification-level
    })

    (ok true)
  )
)

;; Submit repair request
(define-public (submit-repair-request
  (furniture-type (string-ascii 50))
  (repair-type (string-ascii 50))
  (description (string-ascii 500))
  (urgency uint)
  (max-budget uint)
)
  (let ((repair-id (var-get next-repair-id)))
    (asserts! (> (len furniture-type) u0) ERR_INVALID_INPUT)
    (asserts! (> (len repair-type) u0) ERR_INVALID_INPUT)
    (asserts! (and (>= urgency u1) (<= urgency u3)) ERR_INVALID_INPUT)
    (asserts! (> max-budget u0) ERR_INVALID_INPUT)

    (map-set repair-requests repair-id {
      customer: tx-sender,
      furniture-type: furniture-type,
      repair-type: repair-type,
      description: description,
      urgency: urgency,
      max-budget: max-budget,
      assigned-provider: none,
      status: "open",
      quote-amount: u0,
      completion-date: none,
      warranty-period: u0,
      created-at: block-height
    })

    (var-set next-repair-id (+ repair-id u1))
    (ok repair-id)
  )
)

;; Submit quote
(define-public (submit-quote
  (repair-id uint)
  (quote-amount uint)
  (estimated-days uint)
  (warranty-months uint)
  (materials-included bool)
  (quote-notes (string-ascii 300))
)
  (let ((request (unwrap! (map-get? repair-requests repair-id) ERR_NOT_FOUND))
        (provider-info (unwrap! (map-get? repair-providers tx-sender) ERR_UNAUTHORIZED)))

    (asserts! (get active provider-info) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status request) "open") ERR_INVALID_INPUT)
    (asserts! (<= quote-amount (get max-budget request)) ERR_INVALID_INPUT)
    (asserts! (> quote-amount u0) ERR_INVALID_INPUT)

    (map-set repair-quotes {repair-id: repair-id, provider: tx-sender} {
      quote-amount: quote-amount,
      estimated-days: estimated-days,
      warranty-months: warranty-months,
      materials-included: materials-included,
      quote-notes: quote-notes,
      submitted-at: block-height
    })

    (ok true)
  )
)

;; Accept quote
(define-public (accept-quote (repair-id uint) (provider principal))
  (let ((request (unwrap! (map-get? repair-requests repair-id) ERR_NOT_FOUND))
        (quote (unwrap! (map-get? repair-quotes {repair-id: repair-id, provider: provider}) ERR_NOT_FOUND))
        (provider-info (unwrap! (map-get? repair-providers provider) ERR_NOT_FOUND)))

    (asserts! (is-eq (get customer request) tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status request) "open") ERR_INVALID_INPUT)
    (asserts! (get active provider-info) ERR_INVALID_INPUT)

    ;; Transfer payment to escrow
    (try! (stx-transfer? (get quote-amount quote) tx-sender (as-contract tx-sender)))

    (map-set repair-requests repair-id (merge request {
      assigned-provider: (some provider),
      status: "in-progress",
      quote-amount: (get quote-amount quote),
      warranty-period: (get warranty-months quote)
    }))

    (ok true)
  )
)

;; Complete repair
(define-public (complete-repair
  (repair-id uint)
  (before-photos (string-ascii 200))
  (after-photos (string-ascii 200))
  (materials-used (string-ascii 300))
  (work-performed (string-ascii 500))
  (provider-notes (string-ascii 300))
)
  (let ((request (unwrap! (map-get? repair-requests repair-id) ERR_NOT_FOUND))
        (provider-info (unwrap! (map-get? repair-providers tx-sender) ERR_UNAUTHORIZED)))

    (asserts! (is-eq (get assigned-provider request) (some tx-sender)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status request) "in-progress") ERR_INVALID_INPUT)

    (map-set repair-requests repair-id (merge request {
      status: "completed",
      completion-date: (some block-height)
    }))

    (map-set repair-history repair-id {
      before-photos: before-photos,
      after-photos: after-photos,
      materials-used: materials-used,
      work-performed: work-performed,
      customer-rating: none,
      provider-notes: provider-notes
    })

    ;; Pay provider
    (try! (as-contract (stx-transfer? (get quote-amount request) tx-sender tx-sender)))

    ;; Update provider stats
    (map-set repair-providers tx-sender (merge provider-info {
      total-repairs: (+ (get total-repairs provider-info) u1)
    }))

    (ok true)
  )
)

;; Rate repair
(define-public (rate-repair (repair-id uint) (rating uint))
  (let ((request (unwrap! (map-get? repair-requests repair-id) ERR_NOT_FOUND))
        (history (unwrap! (map-get? repair-history repair-id) ERR_NOT_FOUND))
        (provider (unwrap! (get assigned-provider request) ERR_NOT_FOUND))
        (provider-info (unwrap! (map-get? repair-providers provider) ERR_NOT_FOUND)))

    (asserts! (is-eq (get customer request) tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status request) "completed") ERR_INVALID_INPUT)
    (asserts! (is-none (get customer-rating history)) ERR_INVALID_INPUT)
    (asserts! (and (>= rating u1) (<= rating u5)) ERR_INVALID_INPUT)

    (map-set repair-history repair-id (merge history {
      customer-rating: (some rating)
    }))

    ;; Update provider rating
    (let ((current-rating (get rating provider-info))
          (total-repairs (get total-repairs provider-info))
          (new-rating (/ (+ (* current-rating total-repairs) rating) (+ total-repairs u1))))

      (map-set repair-providers provider (merge provider-info {
        rating: new-rating
      }))
    )

    (ok true)
  )
)

;; Read-only Functions

(define-read-only (get-repair-request (repair-id uint))
  (map-get? repair-requests repair-id)
)

(define-read-only (get-provider-info (provider principal))
  (map-get? repair-providers provider)
)

(define-read-only (get-quote (repair-id uint) (provider principal))
  (map-get? repair-quotes {repair-id: repair-id, provider: provider})
)

(define-read-only (get-repair-history (repair-id uint))
  (map-get? repair-history repair-id)
)

;; Admin Functions

(define-public (set-min-deposit (new-deposit uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set min-provider-deposit new-deposit)
    (ok true)
  )
)
