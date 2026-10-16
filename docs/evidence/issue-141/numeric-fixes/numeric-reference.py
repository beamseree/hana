from decimal import Decimal, localcontext
with localcontext() as context:
    context.prec = 200
    for left, right in [('1e-65', '1e-64'), ('5e-65', '2e-64')]:
        print(f'{left} * {right} = {Decimal(left) * Decimal(right)}')
    print('0.5^400 =', Decimal('0.5') ** 400)
    for left, right in [('1e-100', '1'), ('1e-100', '10'), ('1e-128', '1')]:
        print(f'{left} / {right} = {Decimal(left) / Decimal(right)}')
