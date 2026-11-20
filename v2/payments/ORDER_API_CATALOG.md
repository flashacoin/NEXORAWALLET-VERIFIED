# NEXORA V2 Order API catalog configuration

The `nexora-orders` Edge Function reads a server-only product catalog from
`public.nx_wallet_settings`, setting_key `product_catalog`.

Example value shape (DO NOT USE THESE EXAMPLE PRICES):

```json
{
  "example_product": {
    "active": false,
    "description": "Example product",
    "price": 0,
    "currency": "USDT",
    "methods": [],
    "version": "v1"
  }
}
```

- `active` must be true before orders can be created.
- `price` is server-controlled and must be positive.
- `methods` may contain `wallet`, `tron`, or `telegram_stars`.
- Stars are forced to currency XTR.
- TRON payments are forced to currency USDT and network TRON-TRC20.
- The function creates fixed-quantity (1) orders only at this milestone.
- Configure products and prices only after reviewing them in an isolated environment.
- Do not enable the catalog on production until migrations, function security, idempotency races, and API tests have been reviewed.

## API actions
POST to the Edge Function with a bearer token and JSON:
- `{ "action":"create", "product_code":"...", "payment_method":"wallet|tron|telegram_stars", "idempotency_key":"..." }`
- `{ "action":"get", "order_id":"..." }`
- `{ "action":"cancel", "order_id":"..." }`

No client-provided price, currency, status or user_id is trusted.
