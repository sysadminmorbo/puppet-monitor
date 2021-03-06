# modules/monitor/manifests/service.pp - Monitor a service.

# This monitor::service defined type should be used to create a
# check. Don't use the nagios::object classes directly, let this class
# drive them. It will perform all the necessary configuration on both
# the monitored node and the nagios server.

# The resource's name will appear in nagios as the name of the service.

# $command_line is the full command to run. If the check script lives
# in the default nagios plugin directory (and it usually does), you
# can give just the filename. Include all the necessary arguments to
# the script, and make sure you use nagios variables such as
# '$HOSTADDRESS$' for anything which varies between nodes.  If any
# puppet variables in the string get expanded differently on different
# nodes then bad things will happen.

# For checks run on the server (i.e. run_on_agent => false,) Nagios
# expects the $command_line to be the same for every check of the same
# service. If you need to pass an argument which varies between nodes
# to the check script (for example, an IPMI IP address), you need to
# use Nagios' argument macros mechanism. Put the argument(s) in the
# $command_args array, and put '$ARG1$' style placeholders in the
# $command_line. Example:

#    monitor::service { 'ipmi':
#        command_line   => 'check_kvl_ipmi --hostname $ARG1$',
#        command_args   => [$::ipmi_ipaddress],
#        command_source => "puppet:///modules/hardware/check_kvl_ipmi",
#    }

# $command_source is the source url of the check script to use. This
# will be installed to $plugin_path/$basename, where $basename is the
# source url's basename.

# $service_include is the name of a class to include on the nagios
# server. Typically this would ensure that the nagios plugin is
# present on the server to perform the check.

# $run_on_agent defaults to false, which is what you want for
# network-based checks. If your check needs to execute on the
# monitored node, set this to true. monitor::service will then
# configure nrpe locally to execute the check, and configure the
# nagios server to call the check through nrpe.

# $runas sets the user which should run this check. Sometimes the
# check needs to be able to run as a particular user, for example to
# read file contents. If $runas is set, then the command_line is
# changed to prepend 'sudo -u $runas', and sudo is configured to allow
# nrpe to execute the command as that user.

# The host and address are taken from facter and used to create
# nagios' host configuration object.

# The timeout refers specifically to check_nrpe's timeout. Nagios'
# service check timeout is set in nagios.cfg.

# The check_interval is the frequency at which to run this check. What
# this actually means is controlled by the Nagios configuration. By
# default, the units are minutes. At time of writing, the default is
# in nagiosng::object::defaults, and is set to five minutes.

##TODO: servicegroups parameter

define monitor::service (
    $command_line   = false,
    $command_args   = [],
    $command_source = false,
    $plugin_path    = '/usr/lib64/nagios/plugins',
    $server_include = false,
    $run_on_agent   = false,
    $runas          = false,
    $host           = $::fqdn,
    $address        = $::ipaddress,
    $service        = $name,
    $timeout        = 10,
    $check_interval = false,
    $notes_url_fmt  = false,
)
{
    if $notes_url_fmt
    {
        $notes_url = sprintf($notes_url_fmt, $service)
    }
    else
    {
        $real_notes_url_fmt = hiera('monitor::service::notes_url_fmt', false)
        if $real_notes_url_fmt
        {
            $notes_url = sprintf($real_notes_url_fmt, $service)
        }
        else
        {
            $notes_url = false
        }
    }

    # Set the command_name for nagios / nrpe to use. This is based on
    # the resource's $name.
    $safe_name    = regsubst($name, '[/:\n]', '_', 'GM')
    $command_name = "check_${safe_name}"

    if $run_on_agent
    {
        # If run_on_agent is set, it means that this check is not a
        # network service check we can do remotely. It needs to be run
        # on the monitored node ('agent'). So instead of configuring
        # the check on the nagios server, we add the entry to nrpe on
        # the agent, and make the server run check_nrpe.

        # If the $command_line is relative (doesn't start with /)
        # prepend the $plugin_path
        if $command_line !~ /^\//
        {
            $nrpe_command_line = "${plugin_path}/${command_line}"
        }

        if $command_source
        {
            $command_source_basename =
                regsubst($command_source, '^.*/', '')

            file
            { "${plugin_path}/${command_source_basename}":
                owner  => 'nagios',
                group  => 'nagios',
                mode   => 755,
                source => $command_source,
            }

            # Ensure plugin_path exists before managing the check.
            Class['nagiosng::agent::nrpe'] ->
                File["${plugin_path}/${command_source_basename}"]
        }

        if $runas
        {
            $sudo_cmd = "/usr/bin/sudo -u $runas "

            sudo::command
            { $command_name:
                user    => 'nrpe',
                runas   => $runas,
                command => "$nrpe_command_line",
                pass    => false,
            }
        }
        else
        {
            $sudo_cmd = ""
        }

        if ! empty ($command_args)
        {
            fail "command_args not implemented for run_on_agent == true"
        }

        nagiosng::agent::nrpe::check
        { $command_name:
            command_line => "${sudo_cmd}${nrpe_command_line}",
        }

        $real_command_line =
  "\$USER1\$/check_nrpe -H \$HOSTADDRESS\$ -t $timeout -c $command_name"

        # We don't expect a server_include if run_on_agent is true
        $real_server_include = 'nagiosng::server::nrpe'
    }
    else
    {
        if $runas
        {
            fail "runas not implemented for run_on_agent == false"
        }

        if $command_source
        {
            $real_command_source = $command_source
        }
        else
        {
            $real_command_source = false
        }

        # Unless the $command_line is absolute (starts with / or $)
        # prepend the $USER1$ variable so the nagios server can
        # substitute its own plugin path.
        if $command_line =~ /^[\/\$]/
        {
            $real_command_line = $command_line
        }
        else
        {
            $real_command_line = "\$USER1\$/${command_line}"
        }

        $real_server_include = $server_include
    }

    # Make OS icons work in the nagios web interface.
    # Uses the $operatingsystem variable returned by facter to choose
    # the image. This sets both icon_image and statusmap_image, so
    # it's best to pick a png.
    $icon = $operatingsystem ?
    {
        'CentOS'     => 'centos.png',
        'RedHat'     => 'redhat.png',
        'Scientific' => 'scientific.png',
        default      => 'server.png',
    }

    $hostgroup = hiera('monitor::service::hostgroup', $::enc_zone)
    $parents   = hiera('monitor::service::parents', false)

    # The '@@' prefix marks this as an exported resource. It is not
    # created with the rest of the manifest. Instead it's pushed into
    # the puppet database.

    # In nagios::server, there's a collector which looks like
    # '<<| |>>'. When puppet runs on the nagios server, all of
    # these monitoring resources are retrieved from the database
    # and instantiated on the nagios server.

    # In short, this syntax allows the monitored nodes to tell the
    # nagios server what it should be monitoring. See also
    # http://docs.puppetlabs.com/puppet/latest/reference/lang_exported.html
    @@monitor::service_serverside
    { "$host-$service":
        host           => $host,
        hostgroup      => $hostgroup,
        address        => $address,
        parents        => $parents,
        service        => $service,
        server_include => $real_server_include,
        command_line   => $real_command_line,
        command_name   => $command_name,
        command_source => $real_command_source,
        command_args   => $command_args,
        check_interval => $check_interval,
        icon           => $icon,
        notes_url      => $notes_url,
    }
}
