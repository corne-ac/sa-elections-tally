// Tests for MapNavigation (compiled together with Sources/Tally/MapNavigation.swift).
// Fixtures: Gauteng = 3 (JHB 3003, TSH 3004), Eastern Cape = 1 (NMB 1001).
let parent: (Int) -> Int? = { [3003: 3, 3004: 3, 1001: 1][$0] }
var failures = 0, count = 0
func check(_ name: String, _ got: MapAction, _ want: MapAction) {
    count += 1
    if got != want { failures += 1; print("FAIL \(name): got \(got), want \(want)") }
}
let jhbHit = MapHit(detail: nil, context: nil, munic: 3003, province: 3)
let nmbHit = MapHit(detail: nil, context: nil, munic: 1001, province: 1)
let ocean = MapHit()

// National: the unit is the province
check("national click selects province", MapNavigation.action(.national, jhbHit, double: false, selected: nil, parentOf: parent), .select(3))
check("national click again deselects", MapNavigation.action(.national, jhbHit, double: false, selected: 3, parentOf: parent), .select(nil))
check("national double-click opens PROVINCE (the bug)", MapNavigation.action(.national, jhbHit, double: true, selected: 3, parentOf: parent), .openProvince(3))
check("national double-click ocean does nothing", MapNavigation.action(.national, ocean, double: true, selected: nil, parentOf: parent), .none)

// Province: the unit is a municipality inside it
check("province click selects municipality", MapNavigation.action(.province(3), jhbHit, double: false, selected: nil, parentOf: parent), .select(3003))
check("province click outside selects nothing", MapNavigation.action(.province(3), nmbHit, double: false, selected: nil, parentOf: parent), .select(nil))
check("province double-click opens municipality", MapNavigation.action(.province(3), jhbHit, double: true, selected: nil, parentOf: parent), .openMunicipality(3003))
check("province double-click other province moves there", MapNavigation.action(.province(3), nmbHit, double: true, selected: nil, parentOf: parent), .openProvince(1))
check("province double-click ocean goes up", MapNavigation.action(.province(3), ocean, double: true, selected: nil, parentOf: parent), .goUp)

// Municipality: the unit is a ward
let ward23 = MapHit(detail: 79800023, context: nil, munic: 3003, province: 3)
check("municipality click selects ward", MapNavigation.action(.municipality(3003), ward23, double: false, selected: nil, parentOf: parent), .select(79800023))
check("municipality double-click opens ward", MapNavigation.action(.municipality(3003), ward23, double: true, selected: nil, parentOf: parent), .openWard(79800023))
check("municipality double-click neighbour municipality", MapNavigation.action(.municipality(3003), MapHit(munic: 3004, province: 3), double: true, selected: nil, parentOf: parent), .openMunicipality(3004))
check("municipality double-click outside goes up", MapNavigation.action(.municipality(3003), ocean, double: true, selected: nil, parentOf: parent), .goUp)

// Ward: the unit is a voting station
let station = MapHit(detail: 32863013, context: nil, munic: 3003, province: 3)
check("ward click selects station", MapNavigation.action(.ward(munic: 3003, ward: 79800023), station, double: false, selected: nil, parentOf: parent), .select(32863013))
check("ward double-click station selects it", MapNavigation.action(.ward(munic: 3003, ward: 79800023), station, double: true, selected: nil, parentOf: parent), .select(32863013))
check("ward double-click neighbouring ward", MapNavigation.action(.ward(munic: 3003, ward: 79800023), MapHit(context: 79800024, munic: 3003, province: 3), double: true, selected: nil, parentOf: parent), .openWard(79800024))
check("ward double-click other municipality", MapNavigation.action(.ward(munic: 3003, ward: 79800023), MapHit(munic: 3004, province: 3), double: true, selected: nil, parentOf: parent), .openMunicipality(3004))
check("ward double-click outside goes up", MapNavigation.action(.ward(munic: 3003, ward: 79800023), ocean, double: true, selected: nil, parentOf: parent), .goUp)

print("\(count - failures)/\(count) passed")
