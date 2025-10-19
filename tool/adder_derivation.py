from sympy import Symbol, And, Or
from sympy.logic.boolalg import to_dnf

p = [Symbol(f"(a[{i}] & b[{i}])") for i in range(32)]
s = [Symbol(f"(a[{i}] | b[{i}])") for i in range(32)]
c = [p[0]]
for i in range(1, 32):
    c.append(Or(p[i], And(s[i], c[i - 1])))
for i in range(32):
    print(f"    assign c[{i}] = {to_dnf(c[i])};")
