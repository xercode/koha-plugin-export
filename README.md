# Plugin Export

This plugin is intended to create jobs for export records in Koha

# Requirements

- Koha mininum version: 18.11
- Perl modules:
    - JavaScript::Minifier
    - File::Copy
    - File::Temp
    - File::Basename
    - Archive::Zip
    - IO::Tee
    - JSON

# Installation

Download the package file koha-plugin-export.kpz

Login to Koha Admin and go to the plugin screen

Upload Plugin

Go to System preferences, and add this code to IntranetUserJS


```
In English

// Koha Plugin Export
if ($('body#tools_export').length){
    $.get( "/cgi-bin/koha/plugins/run.pl?class=Koha%3A%3APlugin%3A%3AEs%3A%3AXercode%3A%3AExport&method=status", function( response ) {
        if (response.status){
            $('body#tools_export div#bibs form').each(
                function(){

                    $(this).append("<h3>Koha plugin export specific fields</h3><fieldset class='rows'>    <legend>Biblio creation or modification dates (inclusive)</legend>    <ol>        <li>            <label for='filter-creation' class='radiocontainer'> Created in                <input type='radio' name='datecreatedmodified' id='filter-creation' value='datecreated' checked='checked'>            </label>            <label for='filter-modification' class='radiocontainer'> Modified in                <input type='radio' name='datecreatedmodified' id='filter-modification' value='datemodified'>            </label>        </li>        <li>                <label for='start_datecreatedmodified'>Start date:</label>                <input type='text' size='10' id='start_datecreatedmodified' name='start_datecreatedmodified' value='' class='start_datecreatedmodified' />        </li>        <li>            <label for='end_datecreatedmodified'>End date:</label>            <input size='10' id='end_datecreatedmodified' name='end_datecreatedmodified' value='' type='text' class='end_datecreatedmodified' />        </li>    </ol></fieldset>");

                    $(this).validate({
                        rules: {
                            mailto: {
                                email: true
                            }
                        },
                        submitHandler: function(form) {
                            form.submit();
                        }
                    });


                    // New dates
                    setTimeout(function(){
                        var dates = $( ".start_datecreatedmodified, .end_datecreatedmodified" ).datepicker({
                            changeMonth: true,
                            numberOfMonths: 1,
                            onSelect: function( selectedDate ) {
                                var option = $( this ).hasClass("start_datecreatedmodified") ? "minDate" : "maxDate",
                                    instance = $( this ).data( "datepicker" );
                                    date = $.datepicker.parseDate(
                                        instance.settings.dateFormat ||
                                        $.datepicker._defaults.dateFormat,
                                        selectedDate, instance.settings );
                                dates.not( this ).datepicker( "option", option, date );
                            },
                            onClose: function(dateText, inst) {
                                validate_date(dateText, inst);
                            },
                        }).on("change", function(e, value) {
                            if ( ! is_valid_date( $(this).val() ) ) {$(this).val("");}
                        });

                    }, 3000);

                }
            );

            $('body#tools_export div#exporttype form').each(
                function(){ 
                    $(this).attr('action', '/cgi-bin/koha/plugins/run.pl');
                    $(this).append("<input type='hidden' name='class' value='Koha::Plugin::Es::Xercode::Export'/>");
                    $(this).append("<input type='hidden' name='method' value='createjob'/>");
                    $(this).append("<li><label for='mailto'>and use this email to report: </label><input id='mailto' type='text' name='mailto' size='30'/></li>");

                    $(this).validate({
                        rules: {
                            mailto: {
                                email: true
                            }
                        },
                        submitHandler: function(form) {
                            form.submit();
                        }
                    });
                }
            );
        }else{
            $('#exporttype').before('<div class="dialog alert">Koha Plugin Export is installed, but cannot be used yet. Please, contact with your administrator to check the plugin.</div>');
        }
    });
}
```
Create a new letter to send notices:
```
INSERT INTO `letter` (`module`, `code`, `branchcode`, `name`, `is_html`, `title`, `content`, `message_transport_type`, `lang`) VALUES
('backgroundjobs', 'EXPORTPLUGIN', '', 'Export plugin', '1', 'Export finished', '<p>Hello <<borrowers.firstname>>,</p>\r\n<p>your export job is finished. Please visit Koha to download it.</p>\r\n<p>Thank you</p>', 'email', 'default');
```

Add a new cron job:
```
perl [your_plugin_dir]/Koha/Plugin/Es/Xercode/Export/cronjob.pl
```

# Configuration

In the configuration page, you can:
- Enable the plugin
- Establish the directory to store the exported data.
- Set characters to remove from the records.

# Documentation

Run the export job from Tools -> Export data.
