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

**Phase rules**: Do not create Phase 1 issues until all Phase 0 items are covered by existing issues. Check the checklist status below.

---

## Phase 0 — Foundation & Production Readiness

Phase 0 is complete when all items below have corresponding issues AND those issues are marked `done`.

### Phase 0 — Backend (repo:fn-mystore)

Priority order — create issues for these first:

- [ ] `GET /billing/invoices` — return paginated list of Stripe invoices for the company's subscription. Response: `{ invoices: [{ id, amount, status, date, pdfUrl }], hasMore }`. Add to `BillingFunctions.cs`. Add unit tests in `BillingFunctionsTests.cs`.
- [ ] `GET /billing/subscription` — return unified subscription status: plan name, status, current period start/end, trial info, next invoice amount. Consolidates data from Stripe subscription + local DB. Add to `BillingFunctions.cs`. Add tests.
- [ ] Unit tests for `CustomerFunctions` — cover `GET /customers`, `GET /customers/{id}`, `POST /customers`, `PUT /customers/{id}`, `DELETE /customers/{id}`. Follow patterns in `AccountFunctionsTests.cs`. Create `CustomerFunctionsTests.cs`.
- [ ] Unit tests for `InventoryFunctions` — cover all CRUD endpoints plus any search/filter. Create `InventoryFunctionsTests.cs`.
- [ ] Unit tests for `RoleFunctions` — cover `GET /roles`, `GET /roles/{id}`, `POST /roles`, `PUT /roles/{id}`, `DELETE /roles/{id}`. Create `RoleFunctionsTests.cs`.
- [ ] Unit tests for `SalesFunctions` — cover `POST /sales`, `GET /sales`, `GET /sales/{id}`. Create `SalesFunctionsTests.cs`.
- [ ] Unit tests for `CompanyProfileFunctions` — cover `GET /company/profile`, `PUT /company/profile`, `POST /company/logo`. Create `CompanyProfileFunctionsTests.cs`.
- [ ] Unit tests for `GameFunctions` — cover game search and catalog endpoints. Create `GameFunctionsTests.cs`.

### Phase 0 — Frontend (repo:web-mystore)

Priority order — create after backend items are in progress:

- [ ] **MUI theme foundation** — Create `src/theme.js` with a centralized MUI v5 theme: brand color palette (primary/secondary/error/warning), typography scale (h1–h6 + body), component overrides for Button/TextField/Card/DataGrid. Update `main.jsx` to wrap app in `<ThemeProvider>`. Every page must use theme tokens, not hardcoded hex colors or font sizes.
- [ ] **Dashboard page** — Replace any mock/placeholder data with real API calls. Show cards for: total inventory items, customers count, today's sales total, recent sales list (last 5). Use MUI `Card`, `Skeleton` for loading states, `Alert` for errors. Endpoint: use existing `/sales`, `/inventory`, `/customers`.
- [ ] **Inventory page polish** — Replace any basic table/list with MUI `DataGrid` (community edition). Columns: Name, Platform/Category, Condition, Price, Quantity, Actions. Add search bar (client-side filter), "Add Item" button that opens a `Dialog` modal with the add form. Edit in-row or via modal. Proper empty state with illustration text when no items.
- [ ] **Customers page polish** — MUI `DataGrid` with columns: Name, Email, Phone, Points Balance (Phase 0 shows 0), Actions. Row click opens a `Drawer` with customer detail (contact info, purchase history placeholder). Add customer via `Dialog`. Proper loading `Skeleton` and error `Snackbar`.
- [ ] **Users & Roles pages polish** — `UsersPage`: MUI `DataGrid`, invite user via `Dialog` (email + role selector). Deactivate/reactivate via row action. `RolesPage`: list roles with permissions chips, create/edit role via `Dialog`. Use `Chip` components for permissions display.
- [ ] **Sales history page polish** — MUI `DataGrid` with date range filter (`DatePicker` from `@mui/x-date-pickers`). Columns: Date, Customer, Items, Total, Employee. Row click shows receipt in a `Dialog`. Export to CSV button.
- [ ] **Billing settings page polish** — Clean layout using MUI `Paper` sections: Subscription summary card (plan, status, renewal date), Payment methods list with add/remove, Invoice history table. Use `Chip` for subscription status (active=green, trial=orange, cancelled=red).
- [ ] **Company profile page polish** — MUI `Paper` form with sections: Company name/address/phone, Logo upload with preview (drag-and-drop using `react-dropzone` or MUI `Button`), Save button with loading state. Show success `Snackbar` on save.
- [ ] **Global UX patterns** — Audit all pages for: (1) `CircularProgress` or `Skeleton` during all API calls, (2) `Snackbar`/`Alert` for all errors (not `console.error` or silent failures), (3) empty state messages when lists are empty, (4) responsive layout (sidebar collapses on mobile, tables scroll horizontally). Create a shared `useApiCall` hook or error boundary if not present.

---

## Phase 1 — Core Store Features

**Do not start Phase 1 until all Phase 0 issues exist and are `done`.**

### Phase 1 Feature 1: Consignment

Store owners can accept items from customers to sell on their behalf. Revenue is split between the store and the consignor at a configurable percentage.

**Backend (repo:fn-mystore)**:
- [ ] **Consignment DB schema** — SQL migration: `ConsignmentItems` table (Id, CompanyId, CustomerId, Description, AskingPrice, SalePrice nullable, SplitPercent decimal, Status [active/sold/returned], CreatedAt, UpdatedAt). `ConsignmentPayouts` table (Id, ConsignmentItemId, Amount, PaidAt, Notes). Add to `dbproj-mystore`.
- [ ] **Consignment repository** — `IConsignmentRepository` / `ConsignmentRepository` with methods: `GetAllAsync(companyId)`, `GetByIdAsync(id, companyId)`, `CreateAsync(item)`, `UpdateAsync(item)`, `MarkSoldAsync(id, salePrice)`, `GetPayoutsAsync(itemId)`. Dapper + SQL Server.
- [ ] **Consignment service** — `IConsignmentService` / `ConsignmentService` implementing: list items, get item, create item, update item, mark as sold (calculates payout amount = salePrice × splitPercent / 100), process payout, return item to customer. Register in `Program.cs`.
- [ ] **Consignment endpoints** — `ConsignmentFunctions.cs`: `GET /consignment` (list, filterable by status), `GET /consignment/{id}`, `POST /consignment` (create), `PUT /consignment/{id}` (update), `POST /consignment/{id}/sold` (mark sold with sale price), `POST /consignment/{id}/payout` (record payout), `POST /consignment/{id}/return` (return to customer). All require auth + company scoping.
- [ ] **Consignment tests** — Unit tests for `ConsignmentFunctions` and `ConsignmentService`. Cover split calculation logic (verify payout math), status transitions (active→sold, active→returned), and all HTTP endpoints.

**Frontend (repo:web-mystore)**:
- [ ] **Consignment page** — `/consignment` route. MUI `DataGrid` listing all consignment items. Columns: Customer, Description, Asking Price, Split %, Status, Actions. Status chip colored by state. "Add Consignment" button. Filter tabs: All / Active / Sold / Returned.
- [ ] **Consignment detail & actions** — Item detail `Drawer` or modal: show full info, payout calculation preview (e.g. "At asking price: store keeps $X, customer gets $Y"). Buttons: Mark Sold (enter actual sale price), Record Payout, Return to Customer. Disable buttons based on current status.

### Phase 1 Feature 2: Customer Loyalty

Customers earn points on purchases and trade-ins. Points can be redeemed for store credit. Rates are configurable per company.

**Backend (repo:fn-mystore)**:
- [ ] **Loyalty DB schema** — SQL migration: `LoyaltySettings` table (Id, CompanyId, PointsPerDollarSpent decimal, PointsPerDollarTradeIn decimal, RedemptionRate decimal [points per $1 credit], IsEnabled bit). `LoyaltyTransactions` table (Id, CompanyId, CustomerId, Points int, TransactionType [earn_sale/earn_tradein/redeem], ReferenceId nullable, Notes, CreatedAt).
- [ ] **Loyalty repository & service** — `ILoyaltyRepository` / `LoyaltyRepository`: get balance, add transaction, get history, get/update settings. `ILoyaltyService` / `LoyaltyService`: `GetBalance(customerId, companyId)`, `EarnFromSale(customerId, saleAmount, companyId)`, `EarnFromTradeIn(customerId, tradeValue, companyId)`, `Redeem(customerId, points, companyId)` (validates balance, creates transaction, returns credit amount), `GetSettings(companyId)`, `UpdateSettings(settings, companyId)`.
- [ ] **Loyalty endpoints** — `LoyaltyFunctions.cs`: `GET /loyalty/settings`, `PUT /loyalty/settings`, `GET /customers/{id}/loyalty` (balance + recent transactions), `POST /customers/{id}/loyalty/redeem` (redeem points, returns credit amount to apply to sale). Hook `EarnFromSale` into `SalesService` so points are automatically awarded on sale creation.
- [ ] **Loyalty tests** — Cover point calculation (earn rate math), redemption (balance check, credit calculation), settings CRUD, and the sale-integration hook.

**Frontend (repo:web-mystore)**:
- [ ] **Loyalty settings page** — `/settings/loyalty` route, accessible to managers. Form: toggle enable/disable, points per dollar (purchases), points per dollar (trade-ins), redemption rate (points per $1). Save with confirmation. Show example: "A $50 purchase earns X points worth $Y in store credit."
- [ ] **Customer loyalty display** — On `CustomersPage` detail drawer: show points balance prominently. Add "Loyalty History" tab showing transaction list (date, type, points, reference). Add "Redeem Points" button (opens dialog to enter points amount, shows credit value preview, confirms redemption).

### Phase 1 Feature 3: Promotions & Sales

Managers can create store promotions that apply automatically at checkout. Types: percentage discount (store-wide or per category/item), buy X get Y free.

**Backend (repo:fn-mystore)**:
- [ ] **Promotions DB schema** — SQL migration: `Promotions` table (Id, CompanyId, Name, Type [percentage/bxgy], DiscountPercent nullable, BuyQuantity nullable int, GetQuantity nullable int, Scope [store_wide/category/item], ScopeValue nullable [category name or item id], StartDate, EndDate nullable, IsActive bit, CreatedBy userId, CreatedAt). Indexes on CompanyId + IsActive + date range.
- [ ] **Promotions repository & service** — `IPromotionRepository` / `PromotionRepository`: CRUD + `GetActivePromotions(companyId, date)`. `IPromotionService` / `PromotionService`: create, update, deactivate, list, `ApplyPromotions(cartItems, companyId)` → returns line-item discounts. Modify `SalesService.CreateSale` to call `ApplyPromotions` and store the applied discount per line item.
- [ ] **Promotions endpoints** — `PromotionFunctions.cs` (requires Manager role via `[RequirePermission]`): `GET /promotions`, `POST /promotions`, `PUT /promotions/{id}`, `DELETE /promotions/{id}`, `GET /promotions/active` (returns currently active promotions, used by POS). No special permission needed for `GET /promotions/active`.
- [ ] **Promotions tests** — Cover discount calculation (percentage, BXGY), scope filtering (store-wide applies to everything, category/item only applies to matches), date range validity, Manager permission enforcement. Test `ApplyPromotions` with mixed cart scenarios.

**Frontend (repo:web-mystore)**:
- [ ] **Promotions management page** — `/promotions` route (Manager only). MUI `DataGrid` listing promotions: Name, Type, Value, Scope, Dates, Status. "Create Promotion" button opens a `Dialog` with a dynamic form: select type → show relevant fields (percent input, or buy/get quantity inputs), scope selector (store-wide / category / item with search). Active/inactive toggle on each row.
- [ ] **Promotions at checkout** — On `CheckoutPage` (or wherever sales are created): call `GET /promotions/active` on load, display active promotions as info chips, show line-item discounts applied to each item, show promotion savings summary before total. "Apply Manually" option to select a promotion if not auto-applied.
