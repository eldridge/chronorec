package ChronoRec::Provider::Null;

use Moose;

with 'ChronoRec::Role::Provider';

sub initialize			{ }
sub get_task_names		{ () }
sub write_sessions		{ () }

1;
