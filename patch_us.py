import sys

with open("/home/ubuntu/trading-api/api_server.py", "r") as f:
    content = f.read()

# Fix 1: US ccnl field names (ovrs_pdno → pdno, ovrs_item_name → prdt_name)
old1 = '''                for o in raw.get("output") or []:
                    if not o.get("ovrs_pdno"):
                        continue
                    sll_buy = o.get("sll_buy_dvsn_cd", "")
                    orders.append({
                        "order_id":    f"ccld_{o.get('odno', '')}",
                        "ordered_at":  _ordered_at(o.get("ord_dt", ""), o.get("ord_tmd", "")),
                        "ticker":      o.get("ovrs_pdno", ""),
                        "name":        o.get("ovrs_item_name", ""),
                        "order_price": float(o.get("ft_ord_unpr3", 0) or 0),
                        "quantity":    int(float(o.get("ft_ccld_qty", 0) or 0)),
                        "avg_price":   float(o.get("ft_ccld_unpr3", 0) or 0),
                        "status":      "체결",
                        "side":        "BUY" if sll_buy == "02" else "SELL",
                    })'''

new1 = '''                for o in raw.get("output") or []:
                    if not o.get("pdno"):
                        continue
                    sll_buy = o.get("sll_buy_dvsn_cd", "")
                    orders.append({
                        "order_id":    f"ccld_{o.get('odno', '')}",
                        "ordered_at":  _ordered_at(o.get("ord_dt", ""), o.get("ord_tmd", "")),
                        "ticker":      o.get("pdno", ""),
                        "name":        o.get("prdt_name", ""),
                        "order_price": float(o.get("ft_ord_unpr3", 0) or 0),
                        "quantity":    int(float(o.get("ft_ccld_qty", 0) or 0)),
                        "avg_price":   float(o.get("ft_ccld_unpr3", 0) or 0),
                        "status":      "체결",
                        "side":        "BUY" if sll_buy == "02" else "SELL",
                    })'''

if old1 not in content:
    print("ERROR: Fix 1 pattern not found")
    sys.exit(1)
content = content.replace(old1, new1, 1)
print("Fix 1 applied: US ccnl field names")

# Fix 2: Sort order — most recent first
old2 = '    orders.sort(key=lambda x: (0 if x["status"] != "체결" else 1, x["ordered_at"]))'
new2 = '    orders.sort(key=lambda x: x["ordered_at"], reverse=True)'

if old2 not in content:
    print("ERROR: Fix 2 pattern not found")
    sys.exit(1)
content = content.replace(old2, new2, 1)
print("Fix 2 applied: sort most recent first")

with open("/home/ubuntu/trading-api/api_server.py", "w") as f:
    f.write(content)

# Syntax check
import py_compile
try:
    py_compile.compile("/home/ubuntu/trading-api/api_server.py", doraise=True)
    print("Syntax check: PASSED")
except py_compile.PyCompileError as e:
    print(f"Syntax check: FAILED - {e}")
    sys.exit(1)
