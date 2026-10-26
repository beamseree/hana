from decimal import Decimal, localcontext
with localcontext() as context:
    context.prec = 600
    for left, right in [('1e-65', '1e-64'), ('5e-65', '2e-64')]:
        print(f'{left} * {right} = {Decimal(left) * Decimal(right)}')
    print('0.5^400 =', Decimal('0.5') ** 400)
    for left, right in [('1e-100', '1'), ('1e-100', '10'), ('1e-128', '1')]:
        print(f'{left} / {right} = {Decimal(left) / Decimal(right)}')

    maximum = (Decimal(2) ** 128 - 1) * Decimal(10) ** 127
    print('Decimal maximum =', maximum)
    print('2^500 =', Decimal(2) ** 500)
    for left, right, operation in [('5e127', '2', '*'), ('1e127', '10', '*'), ('1e127', '0.1', '/'), ('3e127', '1e38', '*'), ('4e127', '1e38', '*')]:
        result = Decimal(left) * Decimal(right) if operation == '*' else Decimal(left) / Decimal(right)
        print(f'{left} {operation} {right} = {result}; within maximum: {abs(result) <= maximum}')
    for literal in ['340282366920938463463374607431768211455e127', '340282366920938463463374607431768211456e127', '3.40282366920938463463374607431768211456e165', '3402823669209384634633746074317682114551e126', '9.99999999999999999999999999999999999999e-129']:
        value = Decimal(literal)
        print(f'{literal}: within nonzero range: {Decimal("1e-128") <= abs(value) <= maximum}')

    near = Decimal('1e-38')
    for operation, value in [('max + 1', maximum + 1), ('max - -1', maximum - -1), ('max * (1 + 1e-38)', maximum * (1 + near)), ('max / (1 - 1e-38)', maximum / (1 - near)), ('min / (1 + 1e-38)', Decimal('1e-128') / (1 + near))]:
        print(f'{operation}: within nonzero range: {Decimal("1e-128") <= abs(value) <= maximum}')
    for left, right in [('1e126', '340282366920938463463374607431768211454'), ('-1e100', '170141183460469231731687303715884105727e127'), ('-1e-64', '-340282366920938463463374607431768211454e-64'), ('0.3', '340282366920938463463374607431768211455e-64')]:
        print(f'{left} / {right} = {Decimal(left) / Decimal(right)}')
