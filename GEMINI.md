# TicketMaster Cairo Project

## Project Overview

This project implements a TicketMaster smart contract on the Starknet blockchain using the Cairo language. It leverages Ekubo's TWAMM (Time-Weighted Average Market Maker) extension to create a sophisticated, demand-based pricing mechanism for "Dungeon Tickets". The contract is an extension of OpenZeppelin's ERC20 component and includes a state machine to manage the lifecycle of token distribution.

The core functionalities include:
- **Automated Market Making:** Initializes a TWAMM pool on Ekubo to facilitate the sale of Dungeon Tickets.
- **Dynamic Pricing:** The price of tickets is determined by market demand through the TWAMM.
- **Issuance Throttling:** The contract can reduce the rate of ticket issuance if the market price falls below a configurable threshold, and resume when the price recovers.
- **Proceeds Distribution:** Proceeds from ticket sales are split between a treasury and a buyback mechanism for a different token.

## Building and Running

The project uses Scarb for dependency management and Starknet Foundry for testing.

### Prerequisites

- [Scarb](https://docs.swmansion.com/scarb/) v2.12.2+
- [Starknet Foundry](https://foundry-rs.github.io/starknet-foundry/) v0.49.0+

### Setup

1.  **Clone the repository:**
    ```bash
    git clone <repo-url>
    cd ticket-master
    ```

2.  **Install dependencies:**
    ```bash
    scarb build
    ```

### Build

To compile the contract, run:

```bash
scarb build
```

### Testing

The project includes a comprehensive test suite using Starknet Foundry.

-   **Run all tests:**
    ```bash
    snforge test
    ```

-   **Run tests with forking:**
    The tests can be run against a forked mainnet or sepolia environment.
    ```bash
    snforge test --fork mainnet
    snforge test --fork sepolia
    ```

## Development Conventions

### Code Style

The project follows the standard Cairo formatting guidelines. Use `scarb fmt` to format the code.

### Testing Practices

-   **Unit Tests:** Located alongside the source code (e.g., `src/utils.cairo`).
-   **Integration Tests:** Located in the `tests/` directory, covering the full contract lifecycle.
-   **Fork Testing:** Tests are run against forked environments to ensure correct integration with external contracts like Ekubo.

### Contribution Guidelines

1.  Format code with `scarb fmt`.
2.  Run all tests, including fork tests.
3.  Update documentation and tests along with code changes.
4.  Follow Conventional Commits for git history (e.g., `feat:`, `fix:`, `refactor:`).
