package Catalyst::Plugin::Cache::HTTP;

use base qw(Class::Accessor::Fast);

use strict;
use warnings;

use 5.008_001;

use NEXT;

BEGIN {
    require List::Util;
    require HTTP::Headers::ETag;
}

=head1 NAME

Catalyst::Plugin::Cache::HTTP - HTTP/1.1 cache validators for Catalyst

=head1 VERSION

Version 0.001000

=cut

our $VERSION = "0.001000";

__PACKAGE__->mk_accessors(qw(_http_mc_finalized_headers));

=head1 SYNOPSIS

  package MyApp;

  use Catalyst qw(Cache::HTTP);

  
  package MyApp::Controller::Foo;

  sub bar : Local {
    my ($self, $c) = @_;
    my $data = $c->model('MyApp::Model')->fetch_data;
    my $mtime = $data->mod_time;

    ...
    $c->response->headers->last_modified($mtime);
    ...
  }


  package MyApp::View::Any;

  use Digest::MD5 'md5_hex';

  sub process {
    my $self = shift;
    my $c = $_[0];

    $c->response->headers->etag(md5_hex($c->response->body))
      if $c->response->body;

    $c->NEXT::process(@_);
  }

=head1 DESCRIPTION

=head2 RFC 2616 13.3

When a cache has a stale entry that it would like to use as a response to a
client's request, it first has to check with the origin server (or possibly
an intermediate cache with a fresh response) to see if its cached entry is
still usable. We call this "validating" the cache entry. Since we do not
want to have to pay the overhead of retransmitting the full response if the
cached entry is good, and we do not want to pay the overhead of an extra
round trip if the cached entry is invalid, the HTTP/1.1 protocol supports
the use of conditional methods.

The key protocol features for supporting conditional methods are those
concerned with "cache validators." When an origin server generates a full
response, it attaches some sort of validator to it, which is kept with the
cache entry. When a client (user agent or proxy cache) makes a conditional
request for a resource for which it has a cache entry, it includes the
associated validator in the request.

The server then checks that validator against the current validator for the
entity, and, if they match (see section 13.3.3), it responds with a special
status code (usually, 304 (Not Modified)) and no entity-body. Otherwise, it
returns a full response (including entity-body). Thus, we avoid
transmitting the full response if the validator matches, and we avoid an
extra round trip if it does not match.

In HTTP/1.1, a conditional request looks exactly the same as a normal
request for the same resource, except that it carries a special header
(which includes the validator) that implicitly turns the method (usually,
GET) into a conditional.

The protocol includes both positive and negative senses of cache-
validating conditions. That is, it is possible to request either that a
method be performed if and only if a validator matches or if and only if no
validators match.

=head1 INTERNAL METHODS

=head2 finalize_headers

This hooks into the chain of C<finalize_headers> methods and checks the
request headers C<If-Match>, C<If-Unmodified-Since>, C<If-None-Match> and
C<If-Modified-Since> as well as the response headers C<ETag> and
C<Last-Modified>. Sets the status response code to C<304 Not Modified>
if those fields indicate, that the data for the resource has not changed
since the last request from the same client, so the client will use a
locally cache copy of the resource data.

=cut

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
	# RFC 2616 14.28 does not tell what to do when no Last-Modified
	# header exists in the response. This implementation treats this
	# situation as if the resource has been modified now.
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
	if ($method eq 'GET' or $method eq 'HEAD') {
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

=head1 CONFIGURATION

none.

=head1 SEE ALSO

L<Catalyst>, L<http://www.ietf.org/rfc/rfc2616.txt>

=head1 AUTHOR

Bernhard Graf C<< <graf(a)cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-catalyst-plugin-cache-http at rt.cpan.org>, or through the web
interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Catalyst-Plugin-Cache-HTTP>.
I will be notified, and then you'll automatically be notified of progress
on your bug as I make changes.

=head1 COPYRIGHT & LICENSE

Copyright 2008 Bernhard Graf, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.
