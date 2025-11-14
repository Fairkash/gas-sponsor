Gas Sponsor — Fee Abstraction Contract
The Gas Sponsor smart contract enables sponsored transactions by allowing verified users to execute actions without paying gas fees themselves.
Sponsors allocate fee credits to users who can spend them to interact with supported smart contracts.

Features
Fee credits assigned by sponsors to users
Users execute contract calls without direct STX spending
Spending limits prevent abuse
Full transparency via event logs
Supports multiple sponsors and multiple beneficiaries
Optional signature validation to restrict scope

Example Flow
Sponsor registers:
(register-sponsor tx-sender)
Sponsor allocates credit:
(credit-user tx-sender user-address u10000)
User interacts with dApp using credits:
(execute-sponsored {contract:.swap-fee-pool, function:swap, ...})
Sponsor then automatically covers gas cost.

Security
Prevent exceeding allowed credit
Event tracking for audits
Sponsor-controlled account lists
Optional signature requirement to prevent replay attacks
Impossible for users to withdraw sponsor’s funds directly
