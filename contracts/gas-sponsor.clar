;; gas-sponsor.clar
;; ------------------------------------------------------------
;; Gas Sponsor / Meta-transaction Voucher Contract (STX)
;; Owner/admin creates on-chain vouchers which relayers redeem for gas reimbursement.
;; - Admin funds the contract with STX (deposit)
;; - Admin creates vouchers authorizing relayer to claim `amount` microSTX
;; - Relayer calls claim-voucher to receive payment (single-use)
;; - Admin can revoke or extend vouchers; admin can withdraw unused funds
;; - Optional `user` field ties voucher to a specific end-user (for accountability)
;; ------------------------------------------------------------

(define-constant ERR_NOT_ADMIN u100)
(define-constant ERR_ZERO_AMOUNT u101)
(define-constant ERR_VOUCHER_NOT_FOUND u102)
(define-constant ERR_VOUCHER_USED u103)
(define-constant ERR_VOUCHER_EXPIRED u104)
(define-constant ERR_VOUCHER_INVALID_RELAYER u105)
(define-constant ERR_INSUFFICIENT_FUNDS u106)
(define-constant ERR_INVALID_PARAM u107)

;; Admin (dApp operator)
(define-data-var admin principal tx-sender)

;; Contract bookkeeping: total STX deposited (convenience; actual balance can be checked with stx-get-balance)
(define-data-var total-deposited uint u0)

;; Voucher structure:
;; id -> { creator: principal, relayer: (optional principal), user: (optional principal),
;;         amount: uint, expiry-block: (optional uint), used: bool, created-block: uint }
(define-map vouchers
  { id: uint }
  {
    creator: principal,
    relayer: (optional principal),   ;; none => anyone can claim
    user: (optional principal),      ;; optional: voucher intended for a specific user
    amount: uint,
    expiry-block: (optional uint),
    used: bool,
    created-block: uint
  })

(define-data-var next-voucher-id uint u1)

;; Events for indexers
(define-private (ev-deposit (from principal) (amount uint))
  (print { event: "deposit", from: from, amount: amount }))

(define-private (ev-withdraw (to principal) (amount uint))
  (print { event: "withdraw", to: to, amount: amount }))

(define-private (ev-voucher-created (id uint) (creator principal) (relayer (optional principal)) (user (optional principal)) (amount uint) (expiry (optional uint)))
  (print { event: "voucher-created", id: id, creator: creator, relayer: relayer, user: user, amount: amount, expiry: expiry }))

(define-private (ev-voucher-claimed (id uint) (relayer principal) (by principal) (amount uint))
  (print { event: "voucher-claimed", id: id, relayer: relayer, claimed-by: by, amount: amount }))

(define-private (ev-voucher-revoked (id uint) (by principal))
  (print { event: "voucher-revoked", id: id, by: by }))

(define-private (ev-voucher-updated (id uint) (by principal) (amount uint) (expiry (optional uint)))
  (print { event: "voucher-updated", id: id, by: by, amount: amount, expiry: expiry }))

;; -------------------------
;; Admin functions
;; -------------------------

(define-public (set-admin (p principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_NOT_ADMIN))
    (asserts! (is-standard p) (err ERR_INVALID_PARAM))
    (var-set admin p)
    (ok true)))

;; Deposit STX into the sponsor (caller must include STX via stx-transfer? to contract)
;; We require caller to pass amount and perform stx-transfer? in the same call.
(define-public (deposit (amount uint))
  (begin
    (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
    ;; transfer STX from caller into contract
    (try! (stx-transfer? amount tx-sender (as-contract (var-get admin))))
    (var-set total-deposited (+ (var-get total-deposited) amount))
    (ev-deposit tx-sender amount)
    (ok (var-get total-deposited))))

;; Admin withdraw unused funds
(define-public (withdraw (amount uint) (to principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_NOT_ADMIN))
    (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
    (asserts! (is-standard to) (err ERR_INVALID_PARAM))
    ;; ensure contract has enough STX balance
    (let ((bal (stx-get-balance (as-contract tx-sender))))
      (asserts! (>= bal amount) (err ERR_INSUFFICIENT_FUNDS))
      ;; update bookkeeping (best-effort)
      (var-set total-deposited (if (>= (var-get total-deposited) amount) (- (var-get total-deposited) amount) u0))
      (try! (stx-transfer? amount (as-contract tx-sender) to))
      (ev-withdraw to amount)
      (ok true))))

;; Create voucher (admin only)
;; relayer: optional principal if none, anyone may claim
;; user: optional principal if set, voucher intended for specific user (for logging/accounting)
;; amount: microSTX to pay relayer upon claim
;; expiry-block: optional; if set, voucher cannot be claimed after that block
(define-public (create-voucher (relayer (optional principal)) (user (optional principal)) (amount uint) (expiry-block (optional uint)))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR_NOT_ADMIN))
    (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
    ;; validate relayer if provided
    (asserts!
      (if (is-some relayer)
        (is-standard (unwrap-panic relayer))
        true)
      (err ERR_INVALID_PARAM))
    ;; validate user if provided
    (asserts!
      (if (is-some user)
        (is-standard (unwrap-panic user))
        true)
      (err ERR_INVALID_PARAM))
    ;; validate expiry if provided
    (asserts!
      (if (is-some expiry-block)
        (> (unwrap-panic expiry-block) burn-block-height)
        true)
      (err ERR_INVALID_PARAM))
    (let ((vid (var-get next-voucher-id)))
      (var-set next-voucher-id (+ vid u1))
      (map-set vouchers { id: vid }
        { creator: tx-sender,
          relayer: relayer,
          user: user,
          amount: amount,
          expiry-block: expiry-block,
          used: false,
          created-block: burn-block-height })
      (ev-voucher-created vid tx-sender relayer user amount expiry-block)
      (ok vid))))


;; Revoke / mark voucher used by admin (prevent future claim)
(define-public (revoke-voucher (id uint))
  (let ((v? (map-get? vouchers { id: id })))
    (asserts! (is-some v?) (err ERR_VOUCHER_NOT_FOUND))
    (asserts! (> id u0) (err ERR_INVALID_PARAM))
    (let ((v (unwrap-panic v?)))
      (asserts! (is-eq tx-sender (var-get admin)) (err ERR_NOT_ADMIN))
      (map-set vouchers { id: id } (merge v { used: true }))
      (ev-voucher-revoked id tx-sender)
      (ok true))))

;; Update voucher amount / expiry (admin only)
(define-public (update-voucher (id uint) (new-amount uint) (new-expiry (optional uint)))
  (let ((v? (map-get? vouchers { id: id })))
    (asserts! (is-some v?) (err ERR_VOUCHER_NOT_FOUND))
    (asserts! (> id u0) (err ERR_INVALID_PARAM))
    (let ((v (unwrap-panic v?)))
      (asserts! (is-eq tx-sender (var-get admin)) (err ERR_NOT_ADMIN))
      (asserts! (> new-amount u0) (err ERR_ZERO_AMOUNT))
      (if (is-some new-expiry)
        (let ((eb (unwrap-panic new-expiry)))
          (asserts! (> eb burn-block-height) (err ERR_INVALID_PARAM)))
        true)
      (map-set vouchers { id: id } (merge v { amount: new-amount, expiry-block: new-expiry }))
      (ev-voucher-updated id tx-sender new-amount new-expiry)
      (ok true))))

;; -------------------------
;; Relayer / public functions
;; -------------------------

;; Claim voucher (relayer calls to receive payment)
;; - only the relayer specified in voucher may claim (if relayer set)
;; - voucher must exist, not used, not expired, and contract must have enough STX
(define-public (claim-voucher (id uint))
  (let ((v? (map-get? vouchers { id: id })))
    (asserts! (is-some v?) (err ERR_VOUCHER_NOT_FOUND))
    (asserts! (> id u0) (err ERR_INVALID_PARAM))
    (let ((v (unwrap-panic v?)))
      (asserts! (not (get used v)) (err ERR_VOUCHER_USED))
      ;; check expiry
      (let ((exp-opt (get expiry-block v)))
        (if (is-some exp-opt)
          (let ((eb (unwrap-panic exp-opt)))
            (asserts! (<= burn-block-height eb) (err ERR_VOUCHER_EXPIRED)))
          true))
      ;; check relayer match if specified
      (let ((r-opt (get relayer v)))
        (if (is-some r-opt)
          (asserts! (is-eq tx-sender (unwrap-panic r-opt)) (err ERR_VOUCHER_INVALID_RELAYER))
          true))
      ;; ensure contract has funds
      (let ((amt (get amount v))
            (bal (stx-get-balance (as-contract tx-sender))))
        (asserts! (>= bal amt) (err ERR_INSUFFICIENT_FUNDS))
        ;; mark used BEFORE transfer to avoid reentrancy-like issues (clarity is pure but keep pattern)
        (map-set vouchers { id: id } (merge v { used: true }))
        ;; attempt transfer
        (try! (stx-transfer? amt (as-contract tx-sender) tx-sender))
        ;; best-effort update bookkeeping
        (var-set total-deposited (if (>= (var-get total-deposited) amt) (- (var-get total-deposited) amt) u0))
        (ev-voucher-claimed id (if (is-some (get relayer v)) (unwrap-panic (get relayer v)) tx-sender) tx-sender amt)
        (ok true)))))

;; -------------------------
;; Views
;; -------------------------

(define-read-only (get-voucher (id uint))
  (ok (map-get? vouchers { id: id })))

(define-read-only (get-next-voucher-id) (ok (var-get next-voucher-id)))

(define-read-only (get-admin) (ok (var-get admin)))

(define-read-only (get-contract-balance)
  (ok (stx-get-balance (as-contract tx-sender))))

(define-read-only (is-voucher-usable (id uint))
  (let ((v? (map-get? vouchers { id: id })))
    (if (is-none v?)
        (err ERR_VOUCHER_NOT_FOUND)
        (let ((v (unwrap-panic v?)))
          (if (get used v) (ok false)
              (let ((exp (get expiry-block v)))
                (if (is-none exp) (ok true)
                    (ok (<= burn-block-height (unwrap-panic exp))))))))))


