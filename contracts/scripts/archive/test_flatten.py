from verify import _flatten

result = _flatten("ProviderRevenueVault")

if result:
    print(f"OK — {len(result):,} chars")
    print(result[:200])
else:
    print("FAILED")
