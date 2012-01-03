#!/usr/bin/env perl

use MooseX::Declare;

MooseX::Storage::Engine->add_custom_type_handler(
	DateTime =>
		expand		=> sub { DateTime::Format::ISO8601->parse_datetime(shift) },
		collapse	=> sub { shift->iso8601 }
);

{
    package DateTime::Duration;

	sub stringify
	{
		use DateTime::Format::Duration;

		my $d = new DateTime::Format::Duration pattern => '%H:%M:%S', normalize => 1;

		return $d->format_duration(shift);
	}

	use overload '""' => \&stringify;
}

class chronorec with MooseX::Getopt {
	use MooseX::POE::SweetArgs;
	use POE::Wheel::ReadLine;
	use Path::Class::Dir;
	use TryCatch;
	use DateTime;
	use DateTime::Span;
	use Data::Dump 'pp';
	use Data::Dump::Filtered;
	use CHI;
	use Class::Load;
	use Config::INI::Reader;
	use ChronoRec::Provider::Null;

	Data::Dump::Filtered::add_dump_filter(sub { shift->class eq 'DateTime' ? { object => shift->iso8601 } : undef });

	use ChronoRec::Task;
	use ChronoRec::Task::Session;

	has database => (is => 'rw', isa => 'Str', default => 'local');

	has home =>
		is			=> 'ro',
		isa			=> 'Path::Class::Dir',
		lazy_build	=> 1;

	has config =>
		is			=> 'ro',
		isa			=> 'HashRef',
		lazy_build	=> 1;

	has console =>
		is			=> 'ro',
		isa			=> 'POE::Wheel::ReadLine',
		lazy_build	=> 1;

	has store =>
		is			=> 'ro',
		isa			=> 'CHI::Driver',
		lazy_build	=> 1;

	has provider =>
		is			=> 'ro',
		does		=> 'ChronoRec::Role::Provider',
		lazy_build	=> 1;

	has current =>
		is			=> 'rw',
		isa			=> 'ChronoRec::Task';

	method _build_home
	{
		my $path = Path::Class::Dir->new((getpwuid($<))[7] . '/.' . ref $self);

		do { $path->mkpath or die "unable to make path $path: $!" }
			if not -e $path;

		return $path;
	}

	method _build_config
	{
		Config::INI::Reader->read_file($self->home->file('config.ini'));
	}

	method _build_console
	{
		my $wheel = new POE::Wheel::ReadLine InputEvent => 'input', PutMode => 'immediate';

		$wheel->attribs->{completion_function} = sub { $self->complete(@_) };
		$wheel->read_history($self->home->file('history'));
		$wheel->get(ref($self) . '> ');

		return $wheel;
	}

	method _build_store
	{
		new CHI
			driver		=> 'File',
			namespace	=> ref($self),
			root_dir	=> $self->home->subdir('store')->stringify,
			l1_cache	=> { driver => 'Memory', datastore => {} };
	}

	method START
	{
		if (my $hash = $self->store->get('current')) {
			$self->current($self->store->get($hash));
		}

		$self->provider;
		$self->alarm_add(tick => time + 1);
	}

	method _build_provider
	{
		my $args		= $self->config->{Provider} || {};
		my $class		= delete $args->{class} || 'ChronoRec::Provider::Null';
		my $provider	= undef;

		try {
			my ($loaded, $err) = Class::Load::try_load_class($class);

			die $err if not $loaded;

			$provider = $class->new($args);
		} catch ($err) {
			$self->console->put("unable to load provider '$class': $err");

			$provider = new ChronoRec::Provider::Null;
		}

		$provider->initialize;

		return $provider;
	}

	method STOP
	{
		$self->console->write_history($self->home->file('history'));
	}

	sub complete
	{
		my $self	= shift;
		my $text	= shift;
		my $line	= shift;
		my $start	= shift;

		my @candidates = ();

		my $last	= rindex $line, ' ', $start;
		my $context	= $last > 0 ? substr $line, 0, $last : $line;

		#$self->console->put("TEXT: $text");
		#$self->console->put("LINE: $line");
		#$self->console->put("START: $start");
		#$self->console->put("LAST: $last");
		#$self->console->put("CONTEXT: $context");

		if ($context eq 'start' or $context eq 'stop') {
			push @candidates, $self->provider->find_matching_tasks($text);
		}

		if ($context =~ /^\s*$/) {
			push @candidates, 'start' unless $self->current and $self->current->is_active;
			push @candidates, 'stop' if $self->current and $self->current->is_active;
			push @candidates, 'info';
		}

		return @candidates;
	}

	event dump => sub
	{
		my $self = shift;
		my $key	= shift;

		$key = $self->current->hash if not defined $key and $self->current;

		if ($key) {
			$self->console->put(pp $self->store->get($key));
		} else {
			$self->console->put('no key specified and no current task available');
		}

		return 1;
	};

	event tick => sub
	{
		my $self = shift;

		my $prompt = ref $self;

		if ($self->current and $self->current->is_active) {
			$prompt .= ' T=' . $self->current->duration;
			$prompt .= ' S=' . $self->current->get_session(-1)->duration;
			$prompt .= ' ' . $self->current->description;
		}

		$self->console->get($prompt . '> ');
		$self->alarm_add(tick => time + 1);
	};

	event input => sub
	{
		my $self	= shift;
		my $text	= shift || '';
		my $ex		= shift || '';

		$self->alarm_remove_all if $ex eq 'eot';

		my ($op, $args) = split /\s+/, $text, 2;

		return if not defined $op;

		$self->call($op, $args) or $self->console->put("unknown command $op");

		$self->console->addhistory($text);
	};

	event list => sub
	{
		my $self = shift;

		$self->console->put(pp $self->store->get_keys);

		return 1;
	};

	event info => sub
	{
		my $self = shift;
		my $hash = shift || $self->current->hash;

		my $task = $self->store->get($hash);

		$self->console->put('description: ' . $task->description);
		$self->console->put('time: ' . $task->duration);

		return 1;
	};

	event report => sub
	{
		my $self	= shift;
		my $from	= shift; # FIXME: NYI
		my $to		= shift; # FIXME: NYI

		my @keys = grep /^[a-f0-9]{40}$/, $self->store->get_keys;

		my $now			= DateTime->now(time_zone => 'local');
		my $date_from	= $now->clone->truncate(to => 'day');
		my $date_to		= $now->clone->add(days => 1)->truncate(to => 'day');
		my $window		= DateTime::Span->from_datetimes(start => $date_from, end => $date_to);

		my @report		= ();
		my $total		= new DateTime::Duration;

		foreach my $key (@keys) {
			my $task	= $self->store->get($key);
			my $dur		= $task->duration($window);

			$total += $dur;

			$self->console->put(join ' ', $dur, $task->description);
		}

		$self->console->put('-' x 20);
		$self->console->put("$total TOTAL");

		return 1;
	};

	event start => sub {
		my $self = shift;
		my $text = shift;

		if ($self->current and $self->current->is_active) {
			$self->console->put('another task in progress');
			return 1;
		}

		if ($self->current and not defined $text) {
			$self->current->start;
			$self->store->set($self->current->hash => $self->current);

			return 1;
		}

		my $task	= new ChronoRec::Task description => $text;
		my $id		= $task->hash;
		my $expires	= $task->date_created->clone->add(hours => 48)->epoch;

		$task->add_session(new ChronoRec::Task::Session);

		$self->store->set($id => $task => { expires_at => $expires });
		$self->store->set(current => $id);

		$self->current($task);
	};

	event stop => sub
	{
		my $self = shift;
		my $text = shift;

		my $task = $self->current;

		if (not $task or not $task->is_active) {
			$self->console->put('no task in progress');
			return 1;
		}

		$task->stop;
		$self->store->set($task->hash => $task);
	};
}

chronorec->new_with_options;
POE::Kernel->run;

