package chronorec::task::session;

use namespace::autoclean;

use Moose;
use MooseX::Storage;

with Storage format => 'YAML', io => 'File';

has date_start =>
	is			=> 'ro',
	isa			=> 'DateTime',
	required	=> 1,
	default		=> sub { DateTime->now(time_zone => 'local') };

has date_stop =>
	is			=> 'rw',
	isa			=> 'DateTime';

sub duration
{
	my $self = shift;

	my $start	= $self->date_start;
	my $stop	= $self->date_stop || DateTime->now(time_zone => 'local');

	return $stop - $start;
}

1;

