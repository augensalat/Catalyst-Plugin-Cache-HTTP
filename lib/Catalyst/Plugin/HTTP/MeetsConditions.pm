package Catalyst::Plugin::HTTP::MeetsConditions;

use base qw(Class::Accessor::Fast);

use strict;
use warnings;

use 5.008_001;

use NEXT;
use List::Util ();	# don't import!

require HTTP::Headers::ETag;

our $VERSION = "0.001000";

__PACKAGE__->mk_accessors(qw(_http_mc_finalized_headers));

sub finalize_headers {
    my $c = shift;

    return if $c->_http_mc_finalized_headers;

    my $status = $c->_meets_conditions;
    if ($status) {
	$c->response->status($status);
	$c->response->body('');
    }

    $c->_http_mc_finalized_headers(1);	# Kilroy was here

    return $c->NEXT::finalize_headers(@_);
}

# code borrowed from apache 2.2.10 modules/http/http_protocol.c

sub _meets_conditions {
    my $c = $_[0];
    my $req = $c->request;
    my $headers_in = $req->headers;
    my $res = $c->response;
    my $headers_out = $res->headers;
    my $status = $res->status || 200;

    $status < 300 and $status >= 200 or return 0;

    my $etag = $headers_out->etag;
    my $now = time;
    my $mtime = $headers_out->last_modified || $now;
    my (@a, $t);

    if (@a = $headers_in->if_match) {
	# If an If-Match request-header field was given
	# AND the field value is not "*" (meaning match anything)
	# AND if our strong ETag does not match any entity tag in that
	# field, respond with a status of 412 (Precondition Failed).
	return 412
	    if $a[0] ne '"*"' and (
		not defined($etag) or
		substr($etag, 0, 1) eq 'W' or
		not (List::Util::first { $etag eq $_ } @a)
	    );
    }
    elsif ($t = $headers_in->if_unmodified_since and $mtime > $t) {
	# Else if a valid If-Unmodified-Since request-header field was
	# given AND the requested resource has been modified since the
	# time specified in this field, then the server MUST respond
	# with a status of 412 (Precondition Failed).
	return 412;
    }

    my $method = uc $req->method;
    my $not_modified;

    if (@a = $headers_in->if_none_match) {
	# If an If-None-Match request-header field was given
	# AND the field value is "*" (meaning match anything)
	#     OR our ETag matches any of the entity tags in that field, fail.
	#
	# If the request method was GET or HEAD, failure means the server
	#    SHOULD respond with a 304 (Not Modified) response.
	# For all other request methods, failure means the server MUST
	#    respond with a status of 412 (Precondition Failed).
	#
	# GET or HEAD allow weak etag comparison, all other methods require
	# strong comparison.  We can only use weak if it's not a range request.
	if ($method eq 'GET') {
	    if ($a[0] eq '"*"') {
		$not_modified = 1;
	    }
	    elsif (defined $etag) {
		if ($headers_in->header('Range')) {
		    $not_modified = 
			substr($etag, 0, 1) ne 'W' &&
			    !!(List::Util::first { $etag eq $_ } @a);
		}
		else {
		    $not_modified = !!(List::Util::first { $etag eq $_ } @a);
		}
	    }
	}
	else {
	    return 412
		if $a[0] eq '"*"' or
		    defined($etag) and List::Util::first { $etag eq $_ } @a;
	}
    }

    if (
	$method eq 'GET' and
	($not_modified or not @a) and
	$t = $headers_in->if_modified_since
    ) {
	# Else if a valid If-Modified-Since request-header field was given
	# AND it is a GET request
	# AND the requested resource has not been modified since the time
	# specified in this field, then the server MUST
	# respond with a status of 304 (Not Modified).
	# A date later than the server's current request time is invalid.
	$not_modified = $t >= $mtime && $t <= $now;
    }

    return $not_modified ? 304 : 0;
}


1;

__END__

=pod

=head1 NAME

Catalyst::Plugin::HTTP::MeetsConditions

=head1 SYNOPSIS


=head1 DESCRIPTION

=head1 INTERNAL METHODS

=head2 finalize_headers

This method is extended and will extend the expiry time before sending
the response.

=head1 CONFIGURATION

=head1 CAVEATS

=head1 AUTHORS

=head1 COPYRIGHT

