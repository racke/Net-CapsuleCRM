package Net::CapsuleCRM;

use strict;
use warnings;
use Moo;
use Sub::Quote;
use Method::Signatures;
use Cpanel::JSON::XS;
use LWP::UserAgent;
use HTTP::Request::Common;
use XML::Simple;

# ABSTRACT: Connect to the Capsule API (www.capsulecrm.com)

=head1 SYNOPSIS

my $foo = Net::CapsuleCRM->new(
  token => 'xxxx',
  debug => 0,
);

=cut

has 'debug' => (is => 'rw', predicate => 'is_debug');
has 'error' => (is => 'rw', predicate => 'has_error');
has 'token' => (is => 'rw', required => 1);
has 'ua' => (is => 'rw', 
  default => sub { LWP::UserAgent->new( agent => 'Perl Net-CapsuleCRM'); } );
has 'target_domain' => (is => 'rw', default => sub { 'api2.capsulecrm.com' } );
has 'xmls' => ( is => 'rw', default => sub { return XML::Simple->new(
  NoAttr => 1, KeyAttr => [], XMLDecl => 1, SuppressEmpty => 1, ); }
);
has 'def_representation' => (is => 'ro', default => sub { 'hash' });

our %def_cache = ();

method endpoint_uri { return 'https://' . $self->target_domain . '/api/v2/'; }

method _talk($command,$method,$content?) {
    my $uri = URI->new($self->endpoint_uri);
    my $uri_path = $uri->path;

    # append command
    $uri->path($uri_path . $command);

    print "Uri: $uri\n" if $self->debug;

  my $res;
  my $type = ref $content  eq 'HASH' ? 'json' : 'xml';

    my $token = $self->token;

    # common request parameters
    my @req_params = (
        Host => 'api.capsulecrm.com',
        Authorization => "Bearer $token",
    );

    $type = 'json';

  if($method =~ /get/i){
    if(ref $content eq 'HASH') {
      $uri->query_form($content);
  }

    print "Uri: $uri\n" if $self->debug;

    my $request = HTTP::Request->new(
        GET => $uri,
        \@req_params,
    );

    if ($self->debug) {
        print "Request: ", $request->as_string, "\n";
    }

    $res = $self->ua->request($request);

    if ($self->debug) {
        print "Response: ", $res->as_string, "\n";
    }
} elsif ($method =~ /put/i) {
    push @req_params, Content_Type => 'application/json';

    my $request = HTTP::Request->new(
        PUT => $uri,
        \@req_params,
    );

    print "Uri: $uri\n" if $self->debug;

    my $json = encode_json $content;

    $request->content($json);

    if ($self->debug) {
        print "Request: ", $request->as_string, "\n";
    }

    $res = $self->ua->request($request);

    if ($self->debug) {
        print "Response: ", $res->as_string, "\n";
    }
  } else {
    #$content = $self->_template($content) if $content;
    if($type eq 'json') {
      print "Encoding as JSON\n" if $self->debug;
      $content = encode_json $content;
      print "$content\n" if $self->debug;
      $res = $self->ua->request(
        POST $uri,
        Accept => 'application/json', 
        Content_Type => 'application/json',
        Content => $content,
      );
    } else {
      #otherwise XML
      $content = $self->xmls->XMLout($content, RootName => $command);
      print "Encoding as XML\n" if $self->debug;
      $res = $self->ua->request(
        POST $uri,
        Accept => 'text/xml', 
        Content_Type => 'text/xml',
        Content => $content,
      );
    }


  }
  
  if ($res->is_success) {
    print "Server said: ", $res->status_line, "\n" if $self->debug;
    if($res->status_line =~ /^201/) {
      return (split '/', $res->header('Location'))[-1]
    } else {
      if($type eq 'json') {
        return decode_json $res->content;
      } elsif($res->content) {
        return XMLin $res->content;
      } else {
        return 1;
      }
    }
  } else {
    $self->error($res->status_line);
    warn $self->error;
    if ($self->debug) {
      print $res->content;
    }
  }
  
}

=head2 search_parties

Search parties with $q as search term.

Returns array reference with the matching parties.

=cut

method search_parties($q) {
    my $res = $self->_talk('parties/search', 'GET', {
        q => $q,
    });

    return $res->{parties};
}

=head2 find_party_by_email

find by email

=cut

method find_party_by_email($email) {
  my $res = $self->_talk('party', 'GET', {
    email => $email,
    start => 0,
  });
  return $res->{'parties'}->{'person'}->{'id'} || undef;
}

=head2 find_party

find by id

=cut

method find_party($id, $options = {}) {
  my $res = $self->_talk('parties/'.$id, 'GET', $options);
  return $res->{'party'};
}

=head2 create_person

$cap->create_person({
  contacts => {
    email => {
      emailAddress => 'xxx',
    },
    address => {
      type => 'xxx',
      street => "xxx",
      city => 'xxx',
      zip => 'xxx',
      country => 'xxx',
    },
    phone => {
      type => 'Home',
      phoneNumber => '123456',
    },
  },
  title => 'Mr',
  firstName => 'Simon',
  lastName => 'Elliott',
});

=cut

method create_person($data) {
  return $self->_talk('person', 'POST', { person => $data } );
}

=head2 create_organization

See Person

=cut

method create_organisation($data) {
  return $self->_talk('organisation', 'POST', { organisation => $data } );
}

=head2 add_tag

$cap->add_tag($person_id,'customer','difficult');

=cut
method add_tag($id, @tags) {
  # my $data = $self->xmls->XMLout(
  #   { tag => [ map { name => $_ }, @tags ] }, RootName => 'tags'
  # );
  foreach(@tags) {
    $self->_talk("party/$id/tag/$_", 'POST');
  }
}

=head2 custom_fields_definitions

Returns definitions of custom fields for C<$entity>.

The results are cached and can be overriden with settings C<$cache> parameter to 0.

=cut

method custom_fields_definitions ($entity, $cache = 1) {
    my ($res, $defs);

    if (exists $def_cache{$entity}) {
        if ($cache) {
            return $def_cache{$entity};
        }
        else {
            delete $def_cache{$entity};
        }
    }

    $res = $self->_talk("$entity/fields/definitions", 'GET');

    if ($self->def_representation eq 'hash') {
        # turn into a hash with field names as keys
        my %custom_fields;

        for my $entry (@{$res->{definitions}}) {
            my $name = delete $entry->{name};

            $custom_fields{$name} = $entry;
        }

        $defs = \%custom_fields;
    }
    else {
        $defs = $res->{definitions};
    }

    if ($cache) {
        $def_cache{$entity} = $defs;
    }

    return $defs;
}

1;
