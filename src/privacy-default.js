// Starting privacy notice. Review it and edit it under Settings to match how the business works.
module.exports = (s) => `${s.business_name} ("we") runs this website so customers can request building work, get quotes, pay and receive certificates.

What we collect
Your name, email, phone number and address; details and photos of the work you ask for; quotes, invoices and payments; certificates we issue; and records of emails we send you. Card payments are handled by Stripe, so we never see or store your card details.

Why we use it
To give you prices, arrange and carry out the work, take payment, issue certificates, and remind you when a safety check or service is due. Our lawful basis is carrying out our contract with you, our legal obligations (for example keeping financial records and safety certificates), and our legitimate interest in running the business.

Who we share it with
Only the people who need it to do the job: our builders and engineers, our payment provider (Stripe), our email provider and our hosting provider. We never sell your data.

How long we keep it
Invoices and payment records for 6 years, as HMRC requires. Gas and electrical certificates for at least as long as the law and our registration bodies require. Other details for as long as you have an account with us, plus 2 years.

Cookies
We use one cookie to keep you logged in. It is essential for the site to work, so we don't ask for consent and we use no tracking or advertising cookies.

Your rights
You can ask for a copy of your data (use "Download my data" on your account page), ask us to correct it, or ask us to delete it where we don't need to keep it by law. Contact us at ${s.business_email || 'our business email'}. You can also complain to the Information Commissioner's Office at ico.org.uk.`;
