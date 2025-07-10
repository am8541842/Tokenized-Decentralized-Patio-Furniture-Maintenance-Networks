;; Cleaning Schedule Coordination Contract
;; Manages seasonal furniture washing and maintenance scheduling

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_NOT_FOUND (err u101))
(define-constant ERR_INVALID_INPUT (err u102))
(define-constant ERR_INSUFFICIENT_FUNDS (err u103))
(define-constant ERR_ALREADY_EXISTS (err u104))

;; Data Variables
(define-data-var next-schedule-id uint u1)
(define-data-var next-service-id uint u1)
(define-data-var base-cleaning-fee uint u2000)

;; Data Maps
(define-map cleaning-schedules
  uint
  {
    owner: principal,
    furniture-type: (string-ascii 50),
    location: (string-ascii 100),
    frequency: uint,
    next-cleaning: uint,
    active: bool,
    total-paid: uint,
    created-at: uint
  }
)

(define-map service-providers
  principal
  {
    name: (string-ascii 100),
    service-area: (string-ascii 100),
    rating: uint,
    total-services: uint,
    active: bool,
    deposit: uint
  }
)

(define-map cleaning-services
  uint
  {
    schedule-id: uint,
    provider: principal,
    scheduled-date: uint,
    completed: bool,
    payment-amount: uint,
    rating: (optional uint),
    notes: (string-ascii 300)
  }
)

(define-map user-balances principal uint)

;; Public Functions

;; Register as service provider
(define-public (register-provider
  (name (string-ascii 100))
  (service-area (string-ascii 100))
  (deposit uint)
)
  (begin
    (asserts! (>= deposit u10000) ERR_INSUFFICIENT_FUNDS)
    (asserts! (is-none (map-get? service-providers tx-sender)) ERR_ALREADY_EXISTS)

    (try! (stx-transfer? deposit tx-sender (as-contract tx-sender)))

    (map-set service-providers tx-sender {
      name: name,
      service-area: service-area,
      rating: u5,
      total-services: u0,
      active: true,
      deposit: deposit
    })

    (ok true)
  )
)

;; Create cleaning schedule
(define-public (create-schedule
  (furniture-type (string-ascii 50))
  (location (string-ascii 100))
  (frequency uint)
  (first-cleaning uint)
)
  (let ((schedule-id (var-get next-schedule-id)))
    (asserts! (> frequency u0) ERR_INVALID_INPUT)
    (asserts! (> (len furniture-type) u0) ERR_INVALID_INPUT)
    (asserts! (> first-cleaning block-height) ERR_INVALID_INPUT)

    (map-set cleaning-schedules schedule-id {
      owner: tx-sender,
      furniture-type: furniture-type,
      location: location,
      frequency: frequency,
      next-cleaning: first-cleaning,
      active: true,
      total-paid: u0,
      created-at: block-height
    })

    (var-set next-schedule-id (+ schedule-id u1))
    (ok schedule-id)
  )
)

;; Book cleaning service
(define-public (book-service (schedule-id uint) (provider principal) (payment uint))
  (let ((schedule (unwrap! (map-get? cleaning-schedules schedule-id) ERR_NOT_FOUND))
        (provider-info (unwrap! (map-get? service-providers provider) ERR_NOT_FOUND))
        (service-id (var-get next-service-id)))

    (asserts! (is-eq (get owner schedule) tx-sender) ERR_UNAUTHORIZED)
    (asserts! (get active schedule) ERR_INVALID_INPUT)
    (asserts! (get active provider-info) ERR_INVALID_INPUT)
    (asserts! (>= payment (var-get base-cleaning-fee)) ERR_INSUFFICIENT_FUNDS)

    ;; Transfer payment to contract
    (try! (stx-transfer? payment tx-sender (as-contract tx-sender)))

    (map-set cleaning-services service-id {
      schedule-id: schedule-id,
      provider: provider,
      scheduled-date: (get next-cleaning schedule),
      completed: false,
      payment-amount: payment,
      rating: none,
      notes: ""
    })

    ;; Update schedule
    (map-set cleaning-schedules schedule-id (merge schedule {
      next-cleaning: (+ (get next-cleaning schedule) (* (get frequency schedule) u144)),
      total-paid: (+ (get total-paid schedule) payment)
    }))

    (var-set next-service-id (+ service-id u1))
    (ok service-id)
  )
)

;; Complete service
(define-public (complete-service (service-id uint) (notes (string-ascii 300)))
  (let ((service (unwrap! (map-get? cleaning-services service-id) ERR_NOT_FOUND))
        (provider-info (unwrap! (map-get? service-providers tx-sender) ERR_UNAUTHORIZED)))

    (asserts! (is-eq (get provider service) tx-sender) ERR_UNAUTHORIZED)
    (asserts! (not (get completed service)) ERR_INVALID_INPUT)

    (map-set cleaning-services service-id (merge service {
      completed: true,
      notes: notes
    }))

    ;; Pay provider
    (try! (as-contract (stx-transfer? (get payment-amount service) tx-sender tx-sender)))

    ;; Update provider stats
    (map-set service-providers tx-sender (merge provider-info {
      total-services: (+ (get total-services provider-info) u1)
    }))

    (ok true)
  )
)

;; Rate service
(define-public (rate-service (service-id uint) (rating uint))
  (let ((service (unwrap! (map-get? cleaning-services service-id) ERR_NOT_FOUND))
        (schedule (unwrap! (map-get? cleaning-schedules (get schedule-id service)) ERR_NOT_FOUND))
        (provider-info (unwrap! (map-get? service-providers (get provider service)) ERR_NOT_FOUND)))

    (asserts! (is-eq (get owner schedule) tx-sender) ERR_UNAUTHORIZED)
    (asserts! (get completed service) ERR_INVALID_INPUT)
    (asserts! (is-none (get rating service)) ERR_INVALID_INPUT)
    (asserts! (and (>= rating u1) (<= rating u5)) ERR_INVALID_INPUT)

    (map-set cleaning-services service-id (merge service {
      rating: (some rating)
    }))

    ;; Update provider rating
    (let ((current-rating (get rating provider-info))
          (total-services (get total-services provider-info))
          (new-rating (/ (+ (* current-rating total-services) rating) (+ total-services u1))))

      (map-set service-providers (get provider service) (merge provider-info {
        rating: new-rating
      }))
    )

    (ok true)
  )
)

;; Read-only Functions

(define-read-only (get-schedule (schedule-id uint))
  (map-get? cleaning-schedules schedule-id)
)

(define-read-only (get-service (service-id uint))
  (map-get? cleaning-services service-id)
)

(define-read-only (get-provider-info (provider principal))
  (map-get? service-providers provider)
)

(define-read-only (get-base-fee)
  (var-get base-cleaning-fee)
)

;; Admin Functions

(define-public (set-base-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (var-set base-cleaning-fee new-fee)
    (ok true)
  )
)
