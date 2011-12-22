// This is the main layout as a template
var MainView = View.extend({
  container: '#global_wrapper',
  template: 'main'
});


// This is a object for subviews of the main layout
var AppView = View.extend({

  currentPage: null,
  parent: MainView,
  container: '#content',

  // Now that we have basic template inheritance, this can be redone
  postRender: function(oldView, newView) {

    if (AppView.currentPage) {
      $(document.body).removeClass('page-' + AppView.currentPage);
    }

    if (this.name) {
      $(document.body).addClass('page-' + this.name);
      AppView.currentPage = this.name;
    }
  }

});


var LogView = AppView.extend({

  name: 'logs',
  template: 'logs',

  load: function() {
    this.interval = setInterval(function() { LogView.fetchLogs(); }, 5000);
    this.fetchLogs();
  },

  unload: function() {
    clearInterval(this.interval);
  },

  fetchLogs: function() {
    $.get('/logs', function(data) {
      LogView.data.logs = data.list.reverse();
      LogView.render();
    });
  }
});

var StorageOverView = View.extend({template: 'storage-overview'});
var RamOverView = StorageOverView.extend({data: {
  title: "RAM Overview",
  neTitle: 'Total Allocated',
  nwTitle: 'Total in Cluster',
  seTitle: 'In Use',
  sTitle: 'Unused',
  swTitle: 'Unallocated'
}});
var DiskOverView = StorageOverView.extend({data: {
  title: "Disk Overview",
  neTitle: 'Usable Free Space',
  nwTitle: 'Total Cluster Storage',
  seTitle: 'In Use',
  sTitle: 'Other Data',
  swTitle: 'Free'
}});

var ClusterView = AppView.extend({
  name: 'cluster',
  template: 'cluster',
  show: function() {

    if (Data.poolDetails.data.storageTotals) {

      var hdd = Data.poolDetails.data.storageTotals.hdd;
      var ram = Data.poolDetails.data.storageTotals.ram;
      var other = hdd.used - hdd.usedByData;

      RamOverView.data.neVal = ram.quotaUsed;
      RamOverView.data.nwVal = ram.quotaTotal;
      RamOverView.data.seVal = ram.usedByData;
      RamOverView.data.sVal = ram.quotaUsed - ram.usedByData;
      RamOverView.data.swVal = ram.quotaTotal - ram.quotaUsed;
      RamOverView.data.meterColor = '#7EDB49';
      RamOverView.data.meterWidth = (ram.quotaUsed / ram.quotaTotal) * 100;
      RamOverView.data.pointer = (ram.quotaUsed / ram.quotaTotal) * 100;


      DiskOverView.data.neVal = hdd.free;
      DiskOverView.data.nwVal = hdd.total;
      DiskOverView.data.seVal = hdd.usedByData;
      DiskOverView.data.sVal = other;
      DiskOverView.data.swVal = hdd.total - other - hdd.usedByData;
      DiskOverView.data.meterColor = '#FDC90D';
      DiskOverView.data.meterWidth = (other / hdd.total) * 100;
      DiskOverView.pointer = 100;

    }

    this.data.ramOverview = RamOverView.render();
    this.data.diskOverview = DiskOverView.render();
    this.render();
  }
});


var LoginView = AppView.extend({name: 'login', template: 'login'});
var FourOhFourView = AppView.extend({template: 'fourohfour'});
var ServersView = AppView.extend({name: 'servers', template: 'servers'});
var BucketsView = AppView.extend({name: 'buckets', template: 'buckets'});
var ViewsView = AppView.extend({name: 'views', template: 'views'});
var SettingsView = AppView.extend({name: 'settings', template: 'settings'});

