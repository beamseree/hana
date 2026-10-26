import Foundation
for text in ["-0.12", "1e-128", "1e127", "1e128", "340282366920938463463374607431768211455", "3.40282366920938463463374607431768211455e165"] {
    if let d = Decimal(string:text) { print(text, "=>", d, "sign", d.sign, "exponent", d.exponent, "sig", d.significand) }
    else { print(text,"nil") }
}
for (text, shift) in [("1", -129), ("10", -129), ("38725919148493182728180306332863518475", -157), ("1", 128), ("10",127)] {
    var number = Decimal(string:text)!, value = Decimal.zero
    let error = NSDecimalMultiplyByPowerOf10(&value, &number, Int16(shift), .plain)
    let constructed = Decimal(sign:number.sign, exponent:shift, significand:number.significand)
    print("scale",text,shift,error.rawValue,value, "constructor",constructed)
}
for (a,b) in [("1e-65","1e-64"),("5e-65","2e-64"),("1e-100","1"),("1e-100","10")] {
    var left = Decimal(string:a)!, right = Decimal(string:b)!, result = Decimal.zero
    let e = a.contains("65") ? NSDecimalMultiply(&result,&left,&right,.plain) : NSDecimalDivide(&result,&left,&right,.plain)
    print("raw",a,b,e.rawValue,result,"exp",result.exponent)
}
