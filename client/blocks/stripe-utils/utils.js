/* global wc_stripe_payment_request_params */

/**
 * External dependencies
 */
import { getSetting } from '@woocommerce/settings';
import { __ } from '@wordpress/i18n';

/**
 * Internal dependencies
 */
import { normalizeLineItems } from './normalize';
import { errorTypes, errorCodes } from './constants';

/**
 * @typedef {import('./type-defs').StripeServerData} StripeServerData
 * @typedef {import('./type-defs').StripePaymentItem} StripePaymentItem
 * @typedef {import('./type-defs').StripePaymentRequest} StripePaymentRequest
 * @typedef {import('@woocommerce/type-defs/registered-payment-method-props').PreparedCartTotalItem} CartTotalItem
 */

/**
 * Stripe data comes form the server passed on a global object.
 *
 * @return  {StripeServerData} Stripe server data.
 */
const getStripeServerData = () => {
	const stripeServerData = getSetting( 'stripe_data', null );
	if ( ! stripeServerData ) {
		throw new Error( 'Stripe initialization data is not available' );
	}
	return stripeServerData;
};

/**
 * Returns the public api key for the stripe payment method
 *
 * @throws Error
 * @return {string} The public api key for the stripe payment method.
 */
const getApiKey = () => {
	const apiKey = getStripeServerData().publicKey;
	if ( ! apiKey ) {
		throw new Error(
			'There is no api key available for stripe. Make sure it is available on the wc.stripe_data.stripe.key property.'
		);
	}
	return apiKey;
};

/**
 * The total PaymentItem object used for the stripe PaymentRequest object.
 *
 * @param {CartTotalItem} total  The total amount.
 *
 * @return {StripePaymentItem} The PaymentItem object used for stripe.
 */
const getTotalPaymentItem = ( total ) => {
	return {
		label:
			getStripeServerData().stripeTotalLabel ||
			__( 'Total', 'woocommerce-gateway-stripe' ),
		amount: total.value,
	};
};

/**
 * Returns a stripe payment request object
 *
 * @param {Object}          config                  A configuration object for
 *                                                  getting the payment request.
 * @param {Object}          config.stripe           The stripe api.
 * @param {CartTotalItem}   config.total            The amount for the total
 *                                                  (in subunits) provided by
 *                                                  checkout/cart.
 * @param {string}          config.currencyCode     The currency code provided
 *                                                  by checkout/cart.
 * @param {string}          config.countryCode      The country code provided by
 *                                                  checkout/cart.
 * @param {boolean}         config.shippingRequired Whether or not shipping is
 *                                                  required.
 * @param {CartTotalItem[]} config.cartTotalItems   Array of line items provided
 *                                                  by checkout/cart.
 *
 * @return {StripePaymentRequest} A stripe payment request object
 */
const getPaymentRequest = ( {
	stripe,
	total,
	currencyCode,
	countryCode,
	shippingRequired,
	cartTotalItems,
} ) => {
	const options = {
		total: getTotalPaymentItem( total ),
		currency: currencyCode,
		country: countryCode || 'US',
		requestPayerName: true,
		requestPayerEmail: true,
		requestPayerPhone: true,
		requestShipping: shippingRequired,
		displayItems: normalizeLineItems( cartTotalItems ),
	};
	return stripe.paymentRequest( options );
};

/**
 * Creates a payment request using cart data from WooCommerce.
 *
 * @param {Object} stripe - The Stripe JS object.
 * @param {Object} cart - The cart data response from the store's AJAX API.
 *
 * @return {Object} A Stripe payment request.
 */
export const createPaymentRequestUsingCart = ( stripe, cart ) => {
	const options = {
		total: cart.order_data.total,
		currency: cart.order_data.currency,
		country: cart.order_data.country_code,
		requestPayerName: true,
		requestPayerEmail: true,
		requestPayerPhone:
			wc_stripe_payment_request_params.checkout.needs_payer_phone,
		requestShipping: cart.shipping_required ? true : false,
		displayItems: cart.order_data.displayItems,
	};

	// Puerto Rico (PR) is the only US territory/possession that's supported by Stripe.
	// Since it's considered a US state by Stripe, we need to do some special mapping.
	if ( options.country === 'PR' ) {
		options.country = 'US';
	}

	return stripe.paymentRequest( options );
};

/**
 * Utility function for updating the Stripe PaymentRequest object
 *
 * @param {Object}               update                An object containing the
 *                                                     things needed for the
 *                                                     update
 * @param {StripePaymentRequest} update.paymentRequest A Stripe payment request
 *                                                     object
 * @param {CartTotalItem}        update.total          A total line item.
 * @param {string}               update.currencyCode   The currency code for the
 *                                                     amount provided.
 * @param {CartTotalItem[]}      update.cartTotalItems An array of line items
 *                                                     provided by the
 *                                                     cart/checkout.
 */
const updatePaymentRequest = ( {
	paymentRequest,
	total,
	currencyCode,
	cartTotalItems,
} ) => {
	paymentRequest.update( {
		total: getTotalPaymentItem( total ),
		currency: currencyCode,
		displayItems: normalizeLineItems( cartTotalItems ),
	} );
};

/**
 * Utility function for updating the Stripe Payment Request object using cart data form
 * WooCommerce.
 *
 * @param {StripePaymentRequest} paymentRequest - The Stripe Payment Request object.
 * @param {Object} cart - The cart data response from the store's AJAX API.
 */
const updatePaymentRequestWithCart = ( paymentRequest, cart ) => {
	paymentRequest.update( {
		total: cart.order_data.total,
		currency: cart.order_data.currency,
		displayItems: cart.order_data.displayItems,
	} );
};

/**
 * Returns whether or not the current session can do apple pay.
 *
 * @param {StripePaymentRequest} paymentRequest A Stripe PaymentRequest instance.
 *
 * @return {Promise<Object>}  True means apple pay can be done.
 */
const canDoPaymentRequest = ( paymentRequest ) => {
	return new Promise( ( resolve ) => {
		paymentRequest.canMakePayment().then( ( result ) => {
			if ( result ) {
				const paymentRequestType = result.applePay
					? 'apple_pay'
					: 'payment_request_api';
				resolve( { canPay: true, requestType: paymentRequestType } );
				return;
			}
			resolve( { canPay: false } );
		} );
	} );
};

const isNonFriendlyError = ( type ) =>
	[
		errorTypes.INVALID_REQUEST,
		errorTypes.API_CONNECTION,
		errorTypes.API_ERROR,
		errorTypes.AUTHENTICATION_ERROR,
		errorTypes.RATE_LIMIT_ERROR,
	].includes( type );

const getErrorMessageForCode = ( code ) => {
	const messages = {
		[ errorCodes.INVALID_NUMBER ]: __(
			'The card number is not a valid credit card number.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.INVALID_EXPIRY_MONTH ]: __(
			'The card expiration month is invalid.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.INVALID_EXPIRY_YEAR ]: __(
			'The card expiration year is invalid.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.INVALID_CVC ]: __(
			'The card security code is invalid.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.INCORRECT_NUMBER ]: __(
			'The card number is incorrect.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.INCOMPLETE_NUMBER ]: __(
			'The card number is incomplete.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.INCOMPLETE_CVC ]: __(
			'The card security code is incomplete.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.INCOMPLETE_EXPIRY ]: __(
			'The card expiration date is incomplete.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.EXPIRED_CARD ]: __(
			'The card has expired.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.INCORRECT_CVC ]: __(
			'The card security code is incorrect.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.INCORRECT_ZIP ]: __(
			'The card zip code failed validation.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.INVALID_EXPIRY_YEAR_PAST ]: __(
			'The card expiration year is in the past',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.CARD_DECLINED ]: __(
			'The card was declined.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.MISSING ]: __(
			'There is no card on a customer that is being charged.',
			'woocommerce-gateway-stripe'
		),
		[ errorCodes.PROCESSING_ERROR ]: __(
			'An error occurred while processing the card.',
			'woocommerce-gateway-stripe'
		),
	};
	return messages[ code ] || null;
};

const getErrorMessageForTypeAndCode = ( type, code = '' ) => {
	switch ( type ) {
		case errorTypes.INVALID_EMAIL:
			return __(
				'Invalid email address, please correct and try again.',
				'woocommerce-gateway-stripe'
			);
		case isNonFriendlyError( type ):
			return __(
				'Unable to process this payment, please try again or use alternative method.',
				'woocommerce-gateway-stripe'
			);
		case errorTypes.CARD_ERROR:
			return getErrorMessageForCode( code );
		case errorTypes.VALIDATION_ERROR:
			return ''; // These are shown inline.
	}
	return null;
};

/**
 * pluckAddress takes a full address object and returns relevant fields for calculating
 * shipping, so we can track when one of them change to update rates.
 *
 * @param {Object} address          An object containing all address information
 * @param {string} address.country
 * @param {string} address.state
 * @param {string} address.city
 * @param {string} address.postcode
 *
 * @return {Object} pluckedAddress  An object containing shipping address that are needed to fetch an address.
 */
const pluckAddress = ( { country, state, city, postcode } ) => ( {
	country,
	state,
	city,
	postcode: postcode.replace( ' ', '' ).toUpperCase(),
} );

export {
	getStripeServerData,
	getApiKey,
	getTotalPaymentItem,
	getPaymentRequest,
	updatePaymentRequest,
	updatePaymentRequestWithCart,
	canDoPaymentRequest,
	getErrorMessageForTypeAndCode,
	pluckAddress,
};
