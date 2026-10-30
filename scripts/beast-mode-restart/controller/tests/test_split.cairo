use beast_controller_trial::split_proceeds;

#[test]
fn split_boundaries_conserve_every_unit() {
    for amount in array![0_u128, 1, 4, 5, 6, 100, 0xffffffffffffffffffffffffffffffff] {
        for survivor in array![false, true] {
            let (direct, conversion) = split_proceeds(amount, survivor);
            assert(direct <= amount && conversion <= amount, 'BOUNDED');
            assert(direct + conversion == amount, 'CONSERVATION');
        }
    }
}

#[test]
#[fuzzer(runs: 256)]
fn split_assigns_remainder_without_overflow(amount: u128, survivor: bool) {
    let (direct, conversion) = split_proceeds(amount, survivor);
    assert(direct + conversion == amount, 'CONSERVATION');
    if survivor {
        assert(conversion <= direct, 'DAO_MAJORITY');
        assert(amount - conversion * 5 < 5, 'CONVERSION_ROUNDING');
    } else {
        assert(direct <= conversion, 'BUYBACK_MAJORITY');
        assert(amount - direct * 5 < 5, 'VELO_ROUNDING');
    }
}
