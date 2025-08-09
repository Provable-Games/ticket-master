/// Get the maximum allowed duration for TWAMM orders
pub fn get_max_twamm_duration() -> u64 {
    // Maximum step size is 16^18 = 1,152,921,504,606,846,976
    1152921504606846976
}
