# Card art

`darb-digital-card.svg` is the source asset, copied verbatim from
`darbpay-mobile/assets/images/cards/darb-digital-card.svg`. If the design
changes there, re-copy it here and regenerate the PNG.

The rasterized copy consumed by the iOS Wallet extension lives at
`ios/extension/Resources/darb-card-art.png` (1536×969, the Apple card-art
size from Issuer Functional Requirements §7.2: landscape, squared corners,
no PAN/chip/hologram, issuer + PNO logos only).

Regenerate with:

```bash
npx -y sharp-cli@5 -i assets/card-art/darb-digital-card.svg \
  -o ios/extension/Resources/darb-card-art.png resize 1536 969
```
