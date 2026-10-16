import Foundation
for (l,r) in [("1","340282366920938463463374607431768211454"),("1","3.40282366920938463463374607431768211454"),("100000000000000000000000000000000000000","340282366920938463463374607431768211454"),("3","3.40282366920938463463374607431768211455")] {
 var left=Decimal(string:l)!,right=Decimal(string:r)!,result=Decimal.zero
 let error=NSDecimalDivide(&result,&left,&right,.plain)
 print(l,"/",r,error.rawValue,result,"lhscoef",left.significand,left.exponent,"rhscoef",right.significand,right.exponent)
}
