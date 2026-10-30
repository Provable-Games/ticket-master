'use strict';
const MAX_QUOTE_AGE_MS = 60 * 60 * 1000;
function validateQuote(quote, now = Date.now()) {
  if (!Number.isFinite(quote?.usd) || quote.usd <= 0 || !Number.isFinite(quote.updatedAt)
    || now - quote.updatedAt > MAX_QUOTE_AGE_MS || quote.updatedAt > now + 60000)
    throw new Error('A recent LORDS/USD quote is unavailable.');
  return quote;
}
function seedValuation(seedLords, seedTickets, quote, now = Date.now()) {
  validateQuote(quote, now);
  const lords = Number(seedLords), tickets = Number(seedTickets);
  if (!Number.isFinite(lords) || !Number.isFinite(tickets) || lords <= 0 || tickets <= 0)
    throw new Error('Invalid seed amounts.');
  const lordsPerTicket = lords / tickets;
  return { lordsPerTicket, usdPerTicket: lordsPerTicket * quote.usd };
}
module.exports = { validateQuote, seedValuation };
