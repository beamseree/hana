import Foundation
print("greatest", Decimal.greatestFiniteMagnitude, Decimal.greatestFiniteMagnitude.exponent, Decimal.greatestFiniteMagnitude.significand)
for text in ["10", "100000000000000000000000000000000000000", "340282366920938463463374607431768211455", "340282366920938463463374607431768211456", "400000000000000000000000000000000000000"] {
 let coefficient = Decimal(string:text)!
 let value = Decimal(sign:.plus, exponent:127, significand:coefficient)
 print(text,"=>",value,"nan",value.isNaN,"exp",value.exponent,"sig",value.significand)
}
for text in ["10e127","100000000000000000000000000000000000000e127","340282366920938463463374607431768211455e127","340282366920938463463374607431768211456e127","400000000000000000000000000000000000000e127"] {
 print("parse",text,Decimal(string:text) as Any)
}
print("number ctor",NSDecimalNumber(mantissa:10,exponent:127,isNegative:false).decimalValue)
for negative in [false,true] {
 var high=NSDecimalNumber(mantissa:0,exponent:127,isNegative:negative).decimalValue
 var radix=Decimal(string:"18446744073709551616")!
 var product=Decimal.zero
 let error=NSDecimalMultiply(&product,&high,&radix,.plain)
 print("signed empty limb",negative,high,high.isNaN,error.rawValue,product)
}
let positive=NSDecimalNumber(mantissa:10,exponent:127,isNegative:false).decimalValue
print("negated upper value",-positive)
for text in ["340282366920938463463374607431768211456","3.40282366920938463463374607431768211456","3.40282366920938463463374607431768211456e165"] {
 if let value=Decimal(string:text) { print("coefficient boundary",text,value,value.exponent,value.significand) }
 else { print("coefficient boundary",text,"nil") }
}
