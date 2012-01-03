var Data = {};

Data.poolDetails = {
  data: null
};

Data.buckets = Ember.Object.create({
  data: null,

  names: function() {
    var buckets = this.get('data');
    if (buckets===null) {
      return ['this one is empty2'];
    }
    return $.map(buckets, function(bucket) {
      return bucket.name;
    });
  }.property('data')
/*
  namesObject: function() {
    var buckets = this.get('data');
    if (buckets===null) {
      return [{name: 'this one is empty2'}];
    }
    return $.map(buckets, function(bucket) {
      return {'name': bucket.name};
    });
  }.property('data')
*/
});

Data.buckets.addObserver('data', function() {
  console.log('yay a change in data was observed!', this.get('data'));
});
/*
var TestBinding = Ember.Object.create({
  templateName: 'views-tpl',
  //buckets: Data.buckets.get('names')
  //buckets: Data.buckets.get('data')
  //bucketsBinding: 'Data.buckets.data'
  //bucketsBinding: Ember.Binding.oneWay('Data.buckets.data')
  bucketsBinding: Ember.Binding.oneWay('Data.buckets.names')
  //bucketsBinding: 'Data.buckets.names'
});

window.setTimeout(function() {
  console.log('TestBinding:', TestBinding.get('buckets'));
}, 5000);
*/

Data.fetch = {
  // without Ember object
  poolDetails: (function() {
    this.interval = null;

    function fetch() {
      $.get('/pools/default', function(data) {
        Data.poolDetails.data = data;
      });
    }

    fetch();
    this.interval = setInterval(fetch, 5000);

    return this;
  })(),
  // with Ember object
  buckets: (function() {
    this.interval = null;

    function fetch() {
      $.get('/pools/default/buckets', function(data) {
        console.log('try to set bucket data:', data);
        Data.buckets.set('data', data);
      });
    }

    fetch();
    this.interval = setInterval(fetch, 5000);

    return this;
  })()
};




var ViewsView = Ember.View.create({
  templateName: 'views-tpl',
  //buckets: Data.buckets.get('names')
  //bucketsBinding: 'Data.buckets.names'
  bucketsBinding: Ember.Binding.oneWay('Data.buckets.names'),
  //bucketsObjectsBinding: Ember.Binding.oneWay('Data.buckets.namesObjects'),
  alwaysFalse: false
});
ViewsView.appendTo('#global_wrapper');

window.setTimeout(function() {
    console.log('I did it after 2 seconds');
    ViewsView.rerender();
}, 2000);

$('#global_wrapper').on('click', '#rerender-views', function() {
    ViewsView.rerender();
});

//ViewsView.render();
//ViewsView.createElement();
