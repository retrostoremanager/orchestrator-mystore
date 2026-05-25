# RetroStoreManager — Product Requirements Document

## Product Vision
SaaS platform for retro video game and TCG store owners to manage their store operations. Multi-tenant, subscription-based. Targets small-to-medium retro gaming and trading card shops.

## Architecture
- **Backend**: `fn-mystore` — C# Azure Functions (.NET 8), Dapper + SQL Server, xUnit tests
- **Frontend**: `web-mystore` — React 18, TypeScript/JSX, Vite, MUI v5, Redux Toolkit, Vitest
- **Auth**: JWT tokens, multi-tenant by company ID
- **Payments**: Stripe (subscriptions, invoices, payment methods)
- **Routing labels**: `repo:fn-mystore` or `repo:web-mystore`

## How to Use This PRD (Backlog Agent Instructions)

When creating issues, read the EXISTING ISSUES list provided in your prompt. Do NOT create an issue for any feature whose title closely matches an existing issue title. Create issues for the next uncovered items in priority order within the current phase.

**Issue body format** (required for every issue):

```
## What to build
[2-3 sentence description]

## Acceptance criteria
- [ ] [specific, testable criterion]
- [ ] [specific, testable criterion]
...

## Technical notes
[Specific files to create/modify, SQL schema if needed, API routes, test file names]
```

**Phase rules**: Do not create Phase 1 issues until all Phase 0 items are covered by existing issues. Within Phase 1, follow the feature order strictly — do not create Feature N+1 issues until Feature N issues are all created.

---

## Phase 0 — Foundation & Production Readiness

Phase 0 is complete when all items below have corresponding issues AND those issues are marked `done`.

### Phase 0 — Backend (repo:fn-mystore)

- [ ] `GET /billing/invoices` — return paginated list of Stripe invoices for the company subscription. Response: `{ invoices: [{ id, amount, status, date, pdfUrl }], hasMore }`. Add to `BillingFunctions.cs`. Add unit tests in `BillingFunctionsTests.cs`.
- [ ] `GET /billing/subscription` — return unified subscription status: plan name, status, current period start/end, trial info, next invoice amount. Consolidates data from Stripe subscription + local DB. Add to `BillingFunctions.cs`. Add tests.
- [ ] Unit tests for `CustomerFunctions` — cover `GET /customers`, `GET /customers/{id}`, `POST /customers`, `PUT /customers/{id}`, `DELETE /customers/{id}`. Follow patterns in `AccountFunctionsTests.cs`. Create `CustomerFunctionsTests.cs`.
- [ ] Unit tests for `InventoryFunctions` — cover all CRUD endpoints plus any search/filter. Create `InventoryFunctionsTests.cs`.
- [ ] Unit tests for `RoleFunctions` — cover `GET /roles`, `GET /roles/{id}`, `POST /roles`, `PUT /roles/{id}`, `DELETE /roles/{id}`. Create `RoleFunctionsTests.cs`.
- [ ] Unit tests for `SalesFunctions` — cover `POST /sales`, `GET /sales`, `GET /sales/{id}`. Create `SalesFunctionsTests.cs`.
- [ ] Unit tests for `CompanyProfileFunctions` — cover `GET /company/profile`, `PUT /company/profile`, `POST /company/logo`. Create `CompanyProfileFunctionsTests.cs`.
- [ ] Unit tests for `GameFunctions` — cover game search and catalog endpoints. Create `GameFunctionsTests.cs`.

### Phase 0 — Frontend (repo:web-mystore)

- [ ] **MUI theme foundation** — Create `src/theme.js` with a centralized MUI v5 theme: brand color palette (primary/secondary/error/warning), typography scale (h1-h6 + body), component overrides for Button/TextField/Card/DataGrid. Update `main.jsx` to wrap app in `<ThemeProvider>`. Every page must use theme tokens, not hardcoded hex colors or font sizes.
- [ ] **Dashboard page** — Replace any mock/placeholder data with real API calls. Show cards for: total inventory items, customers count, today sales total, recent sales list (last 5). Use MUI `Card`, `Skeleton` for loading states, `Alert` for errors.
- [ ] **Inventory page polish** — MUI `DataGrid` (community edition). Columns: Name, Platform/Category, Condition, Price, Quantity, Actions. Add search bar (client-side filter), "Add Item" button opening a `Dialog`. Proper empty state.
- [ ] **Customers page polish** — MUI `DataGrid`: Name, Email, Phone, Points Balance, Actions. Row click opens a `Drawer` with customer detail. Add customer via `Dialog`. Loading `Skeleton` and error `Snackbar`.
- [ ] **Users & Roles pages polish** — `UsersPage`: MUI `DataGrid`, invite via `Dialog`. `RolesPage`: list roles with permissions `Chip` components, create/edit via `Dialog`.
- [ ] **Sales history page polish** — MUI `DataGrid` with date range filter. Columns: Date, Customer, Items, Total, Employee. Row click shows receipt in `Dialog`. Export to CSV.
- [ ] **Billing settings page polish** — MUI `Paper` sections: Subscription summary card, Payment methods list, Invoice history table. `Chip` for subscription status.
- [ ] **Company profile page polish** — MUI `Paper` form: Company name/address/phone, Logo upload with preview, Save button with loading state. Success `Snackbar` on save.
- [ ] **Global UX patterns** — Audit all pages for: `CircularProgress`/`Skeleton` during API calls, `Snackbar`/`Alert` for all errors, empty state messages, responsive layout. Create shared `useApiCall` hook if not present.

---

## Phase 1 — Core Store Features

**Do not start Phase 1 until all Phase 0 issues exist and are `done`.**

Feature priority order: Consignment -> Trade-ins -> Tax and Receipts -> Customer Loyalty -> Promotions. Do not create Feature N+1 issues until Feature N issues are all created.

### Phase 1 Feature 1: Consignment

Store owners accept items from customers to sell on their behalf. Revenue is split between the store and the consignor at a configurable percentage.

**Backend (repo:fn-mystore)**:
- [ ] **Consignment DB schema** — SQL migration: `ConsignmentItems` table (Id, CompanyId, CustomerId, Description, AskingPrice, SalePrice nullable, SplitPercent decimal, Status [active/sold/returned], CreatedAt, UpdatedAt). `ConsignmentPayouts` table (Id, ConsignmentItemId, Amount, PaidAt, Notes). Add to `dbproj-mystore`.
- [ ] **Consignment repository** — `IConsignmentRepository` / `ConsignmentRepository`: `GetAllAsync(companyId)`, `GetByIdAsync(id, companyId)`, `CreateAsync(item)`, `UpdateAsync(item)`, `MarkSoldAsync(id, salePrice)`, `GetPayoutsAsync(itemId)`. Dapper + SQL Server.
- [ ] **Consignment service** — `IConsignmentService` / `ConsignmentService`: list, get, create, update, mark sold (payout = salePrice x splitPercent / 100), process payout, return to customer. Register in `Program.cs`.
- [ ] **Consignment endpoints** — `ConsignmentFunctions.cs`: `GET /consignment`, `GET /consignment/{id}`, `POST /consignment`, `PUT /consignment/{id}`, `POST /consignment/{id}/sold`, `POST /consignment/{id}/payout`, `POST /consignment/{id}/return`. Auth + company scoping required.
- [ ] **Consignment tests** — Unit tests for `ConsignmentFunctions` and `ConsignmentService`. Cover split calculation, status transitions, all HTTP endpoints.

**Frontend (repo:web-mystore)**:
- [ ] **Consignment page** — `/consignment` route. MUI `DataGrid`: Customer, Description, Asking Price, Split %, Status, Actions. Status chip colored by state. "Add Consignment" button. Filter tabs: All / Active / Sold / Returned.
- [ ] **Consignment detail and actions** — Item detail `Drawer`: full info, payout preview. Buttons: Mark Sold, Record Payout, Return to Customer. Buttons disabled based on current status.

---

### Phase 1 Feature 2: Trade-ins with AI Image Parsing

Store owners buy games from customers for cash or store credit. Staff photograph a pile of games and AI identifies titles and platforms automatically, eliminating manual entry.

**Backend (repo:fn-mystore)**:
- [ ] **Trade-in DB schema** — SQL migration in `dbproj-mystore`: `TradeIns` table (Id, CompanyId, CustomerId nullable, Status [draft/completed/rejected], TotalOfferedValue decimal, TotalAcceptedValue decimal nullable, PaymentType [cash/store_credit], Notes, CreatedBy userId, CreatedAt, CompletedAt nullable). `TradeInItems` table (Id, TradeInId, GameTitle, Platform, Condition [poor/fair/good/excellent], OfferedValue decimal, AcceptedValue decimal nullable, InventoryItemId nullable FK, ParsedByAI bit, CreatedAt). Seed `trade_in.create`, `trade_in.view`, `trade_in.complete` permissions and assign to Owner/Manager/Employee roles.
- [ ] **AI image parsing endpoint** — `POST /trade-ins/parse-image`: accepts `{ imageBase64: string, mimeType: string }`. Calls the Anthropic Claude API (claude-haiku-4-5 for cost efficiency) with a vision prompt asking to identify all video games visible — return title, platform, estimated condition. Returns `{ items: [{ gameTitle, platform, estimatedCondition }] }`. Store `Anthropic__ApiKey` in Azure Function App settings. Use raw HTTP to call the Anthropic messages API. Requires `trade_in.create` permission.
- [ ] **Trade-in repository and service** — `ITradeInRepository` / `TradeInRepository`: `GetAllAsync(companyId)`, `GetByIdAsync`, `CreateAsync`, `UpdateAsync`, `AddItemAsync`, `UpdateItemAsync`, `CompleteAsync(id, paymentType)`. `ITradeInService` / `TradeInService`: create draft, add/update items, complete trade (creates inventory items for accepted games, creates store-credit loyalty transaction if PaymentType is store_credit). Register in `Program.cs`.
- [ ] **Trade-in endpoints** — `TradeInFunctions.cs`: `GET /trade-ins` (list, filter by status/date), `POST /trade-ins`, `GET /trade-ins/{id}`, `PUT /trade-ins/{id}`, `POST /trade-ins/{id}/complete`, `POST /trade-ins/{id}/reject`, `POST /trade-ins/parse-image`. Auth + company scoping required.
- [ ] **Trade-in tests** — Unit tests for `TradeInFunctions` and `TradeInService`. Mock the Anthropic API call (do not make real HTTP calls in tests). Cover: create/complete/reject flows, inventory item creation on completion, store-credit calculation, permission enforcement.

**Frontend (repo:web-mystore)**:
- [ ] **Trade-in page** — `/trade-ins` route. Update existing `TradeInPage.jsx`. Two-panel layout: left panel is editable item list (DataGrid rows: title, platform, condition dropdown, offered value), right panel is summary (total offered, payment type selector cash/store-credit, customer selector optional). "Scan Games" button opens image capture flow. "Add Item Manually" adds blank row. "Complete Trade-in" and "Reject" buttons.
- [ ] **AI image capture flow** — Camera/file-upload dialog: user photographs or uploads an image of games. POST to `/trade-ins/parse-image`, show loading spinner with text "Identifying games...", then populate item list with parsed results. Each AI-parsed item shows an "AI" chip. Staff can edit any field or remove unrecognised items before completing.

---

### Phase 1 Feature 3: Tax and Receipts

Every sale must calculate and display sales tax. After a sale completes, the customer can receive a printable or emailed receipt showing line items, tax, and total.

**Backend (repo:fn-mystore)**:
- [ ] **Tax settings and schema** — SQL migration in `dbproj-mystore`: add `TaxRate decimal(5,4)`, `TaxLabel varchar(50)`, `TaxEnabled bit` to the `Companies` table. Add `GET /company/tax` and `PUT /company/tax` to `CompanyProfileFunctions.cs`. Add `TaxAmount decimal`, `Subtotal decimal` columns to the `Sales` table.
- [ ] **Tax calculation in sales** — Update `SalesService.CreateSale`: if tax enabled, compute `subtotal = sum(item.price * qty)`, `taxAmount = round(subtotal * taxRate, 2)`, `total = subtotal + taxAmount`. Store all three on the `Sales` record. Update `GET /sales` and `GET /sales/{id}` responses to include `subtotal`, `taxAmount`, `total`, `taxRate`, `taxLabel`.
- [ ] **Receipt endpoint and email** — `GET /sales/{id}/receipt` returns: `{ receiptNumber, date, storeName, storeAddress, storePhone, items: [{ name, qty, unitPrice, lineTotal }], subtotal, taxLabel, taxRate, taxAmount, total, paymentMethod, employeeName }`. Add `POST /sales/{id}/receipt/email` to send the receipt HTML to a provided email address via SendGrid or SMTP (use `Email__SmtpHost`, `Email__SmtpPort`, `Email__FromAddress` app settings). Unit tests must cover tax calculation at 0%, a standard rate, and rounding edge cases.

**Frontend (repo:web-mystore)**:
- [ ] **Tax settings UI** — Add "Tax" section to `CompanyProfilePage.jsx`: toggle enable/disable, tax rate input (percent, 2 decimal places), tax label field (default "Sales Tax"). Live example: "A $100.00 sale will include $X.XX in [label]." Save via `PUT /company/tax`. Success `Snackbar`.
- [ ] **Receipt UI** — After sale completes in `CheckoutPage.jsx`, show "Sale Complete" screen with receipt: store name, date, line items, subtotal, tax line (hidden if disabled), total. Two buttons: "Print Receipt" (browser print dialog, print-optimised CSS) and "Email Receipt" (dialog to enter customer email, calls `POST /sales/{id}/receipt/email`). Add "View Receipt" action to rows in `SalesHistoryPage.jsx`.

---

### Phase 1 Feature 4: Customer Loyalty

Customers earn points on purchases and trade-ins. Points can be redeemed for store credit. Rates are configurable per company.

**Backend (repo:fn-mystore)**:
- [ ] **Loyalty DB schema** — SQL migration: `LoyaltySettings` table (Id, CompanyId, PointsPerDollarSpent decimal, PointsPerDollarTradeIn decimal, RedemptionRate decimal [points per $1 credit], IsEnabled bit). `LoyaltyTransactions` table (Id, CompanyId, CustomerId, Points int, TransactionType [earn_sale/earn_tradein/redeem], ReferenceId nullable, Notes, CreatedAt).
- [ ] **Loyalty repository and service** — `ILoyaltyService` / `LoyaltyService`: `GetBalance`, `EarnFromSale`, `EarnFromTradeIn`, `Redeem` (validates balance, creates transaction, returns credit amount), `GetSettings`, `UpdateSettings`. Hook `EarnFromSale` into `SalesService` and `EarnFromTradeIn` into `TradeInService` on completion.
- [ ] **Loyalty endpoints** — `LoyaltyFunctions.cs`: `GET /loyalty/settings`, `PUT /loyalty/settings`, `GET /customers/{id}/loyalty`, `POST /customers/{id}/loyalty/redeem`.
- [ ] **Loyalty tests** — Cover earn rate math, redemption balance check, credit calculation, settings CRUD, sale and trade-in hooks.

**Frontend (repo:web-mystore)**:
- [ ] **Loyalty settings page** — `/settings/loyalty` route (Manager only). Toggle, points-per-dollar (purchases), points-per-dollar (trade-ins), redemption rate. Live example calculation. Save with `Snackbar`.
- [ ] **Customer loyalty display** — On `CustomersPage` detail drawer: points balance, loyalty transaction history tab, "Redeem Points" button with credit preview dialog.

---

### Phase 1 Feature 5: Promotions and Sales Events

Managers create store promotions that apply automatically at checkout. Types: percentage discount (store-wide or per category/item) and buy-X-get-Y-free.

**Backend (repo:fn-mystore)**:
- [ ] **Promotions DB schema** — SQL migration: `Promotions` table (Id, CompanyId, Name, Type [percentage/bxgy], DiscountPercent nullable, BuyQuantity nullable int, GetQuantity nullable int, Scope [store_wide/category/item], ScopeValue nullable, StartDate, EndDate nullable, IsActive bit, CreatedBy userId, CreatedAt).
- [ ] **Promotions repository and service** — `IPromotionService`: CRUD, `GetActivePromotions(companyId, date)`, `ApplyPromotions(cartItems, companyId)` returning line-item discounts. Hook into `SalesService.CreateSale`.
- [ ] **Promotions endpoints** — `PromotionFunctions.cs` (Manager permission): `GET /promotions`, `POST /promotions`, `PUT /promotions/{id}`, `DELETE /promotions/{id}`, `GET /promotions/active` (no special permission needed).
- [ ] **Promotions tests** — Cover percentage and BXGY calculation, scope filtering, date range, Manager permission, mixed-cart `ApplyPromotions` scenarios.

**Frontend (repo:web-mystore)**:
- [ ] **Promotions management page** — `/promotions` route (Manager only). MUI `DataGrid`: Name, Type, Value, Scope, Dates, Status. "Create Promotion" `Dialog` with dynamic form by type. Active/inactive toggle per row.
- [ ] **Promotions at checkout** — In `CheckoutPage.jsx`: load active promotions, show as info chips, apply line-item discounts, show savings summary. "Apply Manually" option.